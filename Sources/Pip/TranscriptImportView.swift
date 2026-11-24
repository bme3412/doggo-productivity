import AppKit
import SwiftUI

struct TranscriptImportView: View {
    @ObservedObject var state: AppState
    @FocusState private var editingText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            DoggoWindowHeader {
                Text(state.draft == nil ? "Paste transcript" : "Review transcript")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            if let draft = state.draft {
                TranscriptReview(draft: draft, library: state.library)
            } else {
                editor
            }
            if let error = state.organizeError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { state.cancelTranscriptImport() }
                    .keyboardShortcut(.cancelAction)
                if state.draft != nil {
                    Button("Back to text") { state.editTranscriptDraft() }
                }
                Spacer()
                if let draft = state.draft {
                    Button("File transcript") { state.fileDraft(draft) }
                        .buttonStyle(.borderedProminent).tint(Theme.trail)
                        .keyboardShortcut(.defaultAction)
                } else {
                    if state.isOrganizing { ProgressView().controlSize(.small) }
                    Button(state.isOrganizing ? "Organizing…" : "Organize transcript") { state.organize() }
                        .buttonStyle(.borderedProminent).tint(Theme.trail)
                        .disabled(state.isOrganizing || state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 660)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
        .onAppear { editingText = state.draftText.isEmpty }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.draftText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 225)
                    .focused($editingText)
                    .accessibilityLabel("Transcript text")
                if state.draftText.isEmpty {
                    Text("Paste the transcript you’d like to save.")
                        .foregroundStyle(.secondary)
                        .padding(13)
                        .allowsHitTesting(false)
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LibraryColors.line))
            HStack {
                Text("\(state.draftText.split(whereSeparator: \.isWhitespace).count.formatted()) words")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Paste from clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        state.draftText = text
                    }
                }
            }
            TextField("Source or link (optional)", text: $state.draftSource)
                .textFieldStyle(.roundedBorder)
            Text("Organizing sends the transcript to Claude to create a summary.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(state.isOrganizing)
    }
}

private struct TranscriptReview: View {
    @ObservedObject var draft: TranscriptDraft
    @ObservedObject var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TextField("Title", text: $draft.record.title).textFieldStyle(.roundedBorder)
            Text("Summary").font(.callout.weight(.semibold))
            TextEditor(text: $draft.record.summary)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 144)
                .accessibilityLabel("Summary")
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LibraryColors.line))
            TranscriptFilingFields(record: $draft.record, library: library)
        }
    }
}

struct TranscriptFilingFields: View {
    @Binding var record: TranscriptRecord
    @ObservedObject var library: LibraryStore
    @State private var lookingUp: String?
    @State private var typedChannel: String?

    private var kind: Binding<TranscriptFiling.Kind> {
        Binding(get: { record.folder.kind }, set: { value in
            var filing = record.folder
            filing.kind = value
            record.filing = filing
        })
    }

    private var videoLink: Binding<String> {
        Binding(get: { record.folder.videoURL ?? YouTubeLink(record.source)?.videoURL?.absoluteString ?? "" },
                set: { value in
            var filing = record.folder
            filing.videoURL = value
            record.filing = filing
        })
    }

    private var channelName: Binding<String> {
        Binding(get: { typedChannel ?? record.folder.channel?.name ?? "" }, set: { name in
            typedChannel = name
            let previous = record.folder.channel
            let next = YouTubeChannel(name: name, url: previous?.name == name ? previous?.url : nil)
            setChannel(next)
        })
    }

    private var lookup: YouTubeLink? {
        guard record.folder.kind == .youtube, record.folder.channel == nil, typedChannel == nil,
              let video = YouTubeLink(videoLink.wrappedValue), video.videoID != nil else { return nil }
        return video
    }

    var body: some View {
        let video = lookup
        VStack(alignment: .leading, spacing: 9) {
            Picker("File under", selection: kind) {
                ForEach(TranscriptFiling.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            if record.folder.kind == .youtube {
                TextField("YouTube video link (optional)", text: videoLink)
                HStack(spacing: 8) {
                    TextField("Channel name", text: channelName)
                    channelPicker
                }
                if lookingUp != nil {
                    ProgressView("Finding channel…").controlSize(.small)
                }
            } else {
                topicFields
            }
            Label(record.path, systemImage: "folder")
                .font(.caption).foregroundStyle(LibraryColors.accent)
        }
        .textFieldStyle(.roundedBorder)
        .task(id: video?.videoID) {
            guard let video, let id = video.videoID else { return }
            lookingUp = id
            defer { if lookingUp == id { lookingUp = nil } }
            if let channel = await video.fetchChannel(), !Task.isCancelled, lookup?.videoID == id {
                setChannel(channel)
            }
        }
    }

    @ViewBuilder
    private var channelPicker: some View {
        let channels = library.youtubeFolders.compactMap(\.channel)
        if !channels.isEmpty {
            Menu("Existing channels") {
                ForEach(channels) { channel in
                    Button(channel.name) {
                        typedChannel = channel.name
                        setChannel(channel)
                    }
                }
            }
            .fixedSize()
        }
    }

    private var topicFields: some View {
        HStack(spacing: 8) {
            TextField("Folder", text: $record.category)
            TextField("Subfolder (optional)", text: $record.subcategory)
            if !library.categories.isEmpty {
                Menu("Existing topics") {
                    ForEach(library.categories) { entry in
                        let title = entry.subcategory.isEmpty ? entry.category : entry.category + " › " + entry.subcategory
                        Button(title) {
                            record.category = entry.category
                            record.subcategory = entry.subcategory
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func setChannel(_ channel: YouTubeChannel?) {
        var filing = record.folder
        filing.channel = channel
        record.filing = filing
    }
}

struct RefileTranscriptView: View {
    @ObservedObject var library: LibraryStore
    let onSave: (Int64) -> Void
    @State private var record: TranscriptRecord
    @State private var saveError = false
    @Environment(\.dismiss) private var dismiss

    init(record: TranscriptRecord, library: LibraryStore, onSave: @escaping (Int64) -> Void) {
        _record = State(initialValue: record)
        self.library = library
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            DoggoWindowHeader {
                Text("Change folder").font(.system(size: 24, weight: .semibold, design: .serif))
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            Text(record.title).foregroundStyle(.secondary)
            TranscriptFilingFields(record: $record, library: library)
            if saveError { Text("Doggo couldn’t change this folder.").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save folder") {
                    record.prepareFiling()
                    if library.update(record) {
                        onSave(record.id)
                        dismiss()
                    } else {
                        saveError = true
                    }
                }
                .buttonStyle(.borderedProminent).tint(Theme.trail)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(21)
        .frame(width: 550)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
    }
}

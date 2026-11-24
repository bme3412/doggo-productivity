import AppKit
import SwiftUI

enum LibraryColors {
    static let paper = tone(0xFCF8F0, dark: 0x252422)
    static let shelf = tone(0xF2EBDF, dark: 0x2D2B28)
    static let accent = tone(0x425F52, dark: 0xA9C8AF)
    static let line = tone(0xDFD5C6, dark: 0x46423C)

    private static func tone(_ light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private enum LibraryFilter: Hashable {
    case all, todos, youtube, channel(String), category(String), subcategory(String, String)
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var state: AppState

    @State private var filter: LibraryFilter = .all
    @State private var selection: Int64?
    @State private var query = ""
    @State private var searchIDs: [Int64]?
    @State private var answer: String?
    @State private var answerPassages: [Passage] = []
    @State private var asking = false
    @State private var showingAnswer = false
    @State private var youtubeExpanded = true
    @State private var topicsExpanded = false
    @State private var expandedCategories: Set<String> = []

    private var categories: [String] { Set(store.categories.map(\.category)).sorted() }

    private var visible: [TranscriptRecord] {
        let channelID: String?
        if case .channel(let id) = filter { channelID = id } else { channelID = nil }
        let channelRecords = channelID.flatMap { key in store.youtubeFolders.first { $0.id == key }?.transcriptIDs }
        let rows = store.records.filter { record in
            switch filter {
            case .all, .todos: return true
            case .youtube: return record.folder.kind == .youtube
            case .channel: return channelRecords?.contains(record.id) == true
            case .category(let category): return record.category == category
            case .subcategory(let category, let subcategory):
                return record.category == category && record.subcategory == subcategory
            }
        }
        guard let searchIDs else { return rows }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return searchIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            HSplitView {
                shelf.padding(.trailing, 6)
                    .frame(minWidth: 245, idealWidth: 280, maxWidth: 345)
                Group {
                    if let record = store.records.first(where: { $0.id == selection }) {
                        TranscriptReader(record: record, store: store, onSelect: openTranscript)
                            .id(record.id)
                    } else {
                        emptyReader
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .doggoWindowCard()
                    }
                }
                .padding(.leading, 6)
                .frame(minWidth: 485, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
        .onAppear { selectVisible() }
        .onChange(of: query) { _, _ in search() }
        .onChange(of: filter) { _, _ in selectVisible() }
        .onChange(of: store.records) { _, _ in search() }
        .onChange(of: state.filedTranscriptID) { _, id in
            if let id { openFiledTranscript(id) }
        }
        .sheet(isPresented: Binding(
            get: { state.showingTranscriptImport },
            set: { if !$0 { state.cancelTranscriptImport() } }
        )) {
            TranscriptImportView(state: state)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(search)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: 410)
            .frame(height: 32)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(LibraryColors.line).allowsHitTesting(false) }

            Button("Ask Doggo", action: ask)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || asking)
                .popover(isPresented: $showingAnswer, arrowEdge: .bottom) {
                    answerView
                }

            Spacer(minLength: 8)
            Button { state.startPaste() } label: {
                Label("Paste transcript", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent).tint(Theme.trail)
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .vertical) {
                folderTree
                ScrollView { folderTree }
            }
            .frame(maxHeight: 228, alignment: .top)
            .background(LibraryColors.shelf)

            Rectangle().fill(LibraryColors.line).frame(height: 1)
            if filter == .todos {
                todoList
            } else {
                List(visible, selection: $selection) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.title).font(.system(size: 14, weight: .medium))
                            .lineLimit(3)
                        Text(record.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tag(record.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if visible.isEmpty {
                        Text(searchIDs == nil ? "No transcripts here yet." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .doggoWindowCard()
    }

    private var folderTree: some View {
        VStack(alignment: .leading, spacing: 3) {
            folderRow("All transcripts", icon: "tray.full", filter: .all)
            folderRow("To-dos", icon: "checklist", filter: .todos)
            DisclosureGroup(isExpanded: $youtubeExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.youtubeFolders) { folder in
                        folderRow(folder.title, icon: "folder", filter: .channel(folder.id))
                            .help(folder.channel?.url?.absoluteString ?? folder.title)
                    }
                }
                .padding(.leading, 24)
            } label: {
                folderRow("YouTube", icon: "play.rectangle", filter: .youtube)
            }
            if !categories.isEmpty {
                DisclosureGroup("Topics", isExpanded: $topicsExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(categories, id: \.self) { category in
                            topicFolder(category)
                        }
                    }
                    .padding(.leading, 18)
                }
                .padding(.top, 3)
            }
        }
        .padding(11)
        .font(.callout)
    }

    @ViewBuilder
    private func topicFolder(_ category: String) -> some View {
        let subfolders = store.categories.filter { $0.category == category && !$0.subcategory.isEmpty }
        if subfolders.isEmpty {
            folderRow(category, icon: "folder", filter: .category(category))
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expandedCategories.contains(category) }, set: {
                if $0 { expandedCategories.insert(category) } else { expandedCategories.remove(category) }
            })) {
                ForEach(subfolders) { entry in
                    folderRow(entry.subcategory, icon: "folder", filter: .subcategory(category, entry.subcategory))
                        .padding(.leading, 19)
                }
            } label: {
                folderRow(category, icon: "folder", filter: .category(category))
            }
        }
    }

    private func folderRow(_ title: String, icon: String, filter choice: LibraryFilter) -> some View {
        Button {
            filter = choice
            if choice == .youtube { youtubeExpanded = true }
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(filter == choice ? LibraryColors.accent.opacity(0.13) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == choice ? .isSelected : [])
    }

    private var todoList: some View {
        let open = visible.flatMap { record in
            record.todos.filter { !record.doneTodos.contains($0) }.map { (record, $0) }
        }
        return List {
            if open.isEmpty { Text("No open to-dos.").foregroundStyle(.secondary) }
            ForEach(Array(open.enumerated()), id: \.offset) { _, pair in
                let (record, todo) = pair
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        var updated = record
                        updated.doneTodos.append(todo)
                        store.update(updated)
                    } label: { Image(systemName: "circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mark done")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(todo).fixedSize(horizontal: false, vertical: true)
                        Button(record.title) { openTranscript(record.id) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyReader: some View {
        ContentUnavailableView(store.records.isEmpty ? "Your reading library" : "Pick a transcript",
                               systemImage: "book",
                               description: Text(store.records.isEmpty
                                                 ? "Paste a transcript to create a summary and save highlights."
                                                 : "Choose a transcript from the list."))
    }

    private var answerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if asking {
                ProgressView("Reading your library…").controlSize(.small)
            } else if let answer {
                ScrollView {
                    Text(answer).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                if !answerPassages.isEmpty {
                    Menu("Open a source") {
                        ForEach(Array(answerPassages.enumerated()), id: \.offset) { index, passage in
                            Button("[\(index + 1)] \(passage.title)") {
                                openTranscript(passage.transcriptID)
                                showingAnswer = false
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(LibraryColors.paper)
    }

    private func selectVisible() {
        guard filter != .todos, !visible.contains(where: { $0.id == selection }) else { return }
        selection = visible.first?.id
    }

    private func openTranscript(_ id: Int64) {
        if !visible.contains(where: { $0.id == id }) {
            query = ""
            searchIDs = nil
            filter = .all
        }
        selection = id
    }

    private func openFiledTranscript(_ id: Int64) {
        if let folder = store.youtubeFolders.first(where: { $0.transcriptIDs.contains(id) }) {
            filter = .channel(folder.id)
            youtubeExpanded = true
            query = ""
            searchIDs = nil
            selection = id
        } else {
            openTranscript(id)
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchIDs = text.isEmpty ? nil : store.searchIDs(text)
        selectVisible()
    }

    private func ask() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        showingAnswer = true
        answerPassages = []
        let passages = store.passages(for: text)
        Task { @MainActor in
            defer { asking = false }
            do {
                answer = try await Archivist.answer(question: text, passages: passages)
                answerPassages = passages
            } catch {
                answer = error.localizedDescription
            }
        }
    }
}

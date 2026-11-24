import AppKit
import SwiftUI

private enum ReaderTab: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"
    case highlights = "Highlights"

    var part: TranscriptText? {
        switch self {
        case .summary: return .summary
        case .transcript: return .transcript
        case .highlights: return nil
        }
    }
}

private struct ReaderLocation: Identifiable {
    let title: String
    let offset: Int
    var id: Int { offset }
}

private struct ReaderJump {
    let id = UUID()
    let offset: Int
}

private struct ReaderDocument {
    let body: NSAttributedString
    let headings: [ReaderLocation]
    var cues: [(seconds: Int, offset: Int)] = []
    var previousLayout: TranscriptProjection?

    func location(at seconds: Int) -> Int? {
        cues.last(where: { $0.seconds <= seconds })?.offset ?? cues.first?.offset
    }

    func selection(at range: NSRange) -> String? {
        guard range.location >= 0, range.location < body.length, range.length > 0,
              range.length <= body.length - range.location else { return nil }
        return (body.string as NSString).substring(with: range)
    }

    func range(of highlight: TranscriptHighlight) -> NSRange? {
        if selection(at: highlight.range) == highlight.text { return highlight.range }
        if let range = previousLayout?.range(of: highlight) { return range }
        let plain = body.string as NSString
        let match = plain.range(of: highlight.text, options: .literal)
        guard match.location != NSNotFound else { return nil }
        let remainder = NSRange(location: NSMaxRange(match), length: plain.length - NSMaxRange(match))
        guard plain.range(of: highlight.text, options: .literal, range: remainder).location == NSNotFound else {
            return nil
        }
        return match
    }

    static func summary(_ record: TranscriptRecord) -> Self {
        let body = NSMutableAttributedString(string: "")
        var headings: [ReaderLocation] = []

        func heading(_ text: String, time: String? = nil) {
            headings.append(ReaderLocation(title: text, offset: body.length))
            body.append(NSAttributedString(string: text + "\n", attributes: style(
                font: serif(20, weight: .semibold), before: 9, after: time == nil ? 6 : 2
            )))
            if let time, let seconds = TranscriptTimecode.seconds(from: time) {
                var attributes = style(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                       color: .linkColor, after: 5)
                attributes[.link] = URL(string: "doggo-transcript://time/\(seconds)")
                body.append(NSAttributedString(string: "\(time) · Open in transcript\n", attributes: attributes))
            }
        }

        func paragraph(_ text: String, size: CGFloat = 15) {
            body.append(NSAttributedString(string: text + "\n", attributes: style(font: serif(size), after: 12)))
        }

        if !record.summary.isEmpty {
            heading("Overview")
            for block in record.summary.components(separatedBy: "\n\n") where !block.isEmpty {
                paragraph(block, size: 17)
            }
        }
        if !record.keyIdeas.isEmpty {
            heading("Key takeaways")
            for idea in record.keyIdeas { paragraph("•  " + idea) }
        }
        for chapter in record.chapters {
            heading(chapter.title, time: chapter.start)
            paragraph(chapter.summary)
        }
        if !record.todos.isEmpty {
            heading("To-dos")
            for todo in record.todos {
                paragraph((record.doneTodos.contains(todo) ? "✓  " : "○  ") + todo)
            }
        }
        return Self(body: body, headings: headings)
    }

    static func transcript(_ source: String, chapters: [Chapter]) -> Self {
        let paragraphs = TranscriptParagraphs(source: source, chapters: chapters)
        let body = NSMutableAttributedString(string: "")
        let prose = style(font: serif(16), after: 14, lineSpacing: 5)
        let time = style(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                         color: .secondaryLabelColor, after: 3)
        let heading = style(font: serif(21, weight: .semibold), before: 12, after: 5)
        for block in paragraphs.blocks {
            let attributes: [NSAttributedString.Key: Any]
            switch block.style {
            case .prose: attributes = prose
            case .timecode: attributes = time
            case .heading: attributes = heading
            }
            body.append(NSAttributedString(string: block.text, attributes: attributes))
        }
        return Self(body: body, headings: [], cues: paragraphs.cues, previousLayout: paragraphs.projection)
    }

    private static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    private static func style(font: NSFont, color: NSColor = .labelColor, before: CGFloat = 0,
                              after: CGFloat, lineSpacing: CGFloat = 3) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }
}

struct TranscriptReader: View {
    let record: TranscriptRecord
    @ObservedObject var store: LibraryStore
    var onSelect: (Int64) -> Void

    @State private var tab: ReaderTab = .summary
    @State private var transcript: ReaderDocument?
    @State private var highlights: [TranscriptHighlight] = []
    @State private var selection: NSRange?
    @State private var jump: ReaderJump?
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var changingFolder = false

    private var document: ReaderDocument? {
        switch tab {
        case .summary: return .summary(record)
        case .transcript: return transcript
        case .highlights: return nil
        }
    }

    private var sourceURL: URL? {
        if record.folder.kind == .youtube,
           let link = YouTubeLink(record.folder.videoURL ?? record.source)?.videoURL {
            return link
        }
        guard let url = URL(string: record.source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 12) {
            titleCard
            readingCard
        }
        .onAppear { highlights = store.highlights(for: record.id) }
        .sheet(isPresented: $changingFolder) {
            RefileTranscriptView(record: record, library: store, onSave: onSelect)
        }
        .alert("Delete this transcript?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if !store.delete(id: record.id) { problem = "Doggo couldn’t delete this transcript." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved transcript and its highlights.")
        }
    }

    private var titleCard: some View {
        VStack(spacing: 0) {
            DoggoWindowHeader {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.path).font(.caption.weight(.semibold)).foregroundStyle(Theme.reportHighlight)
                    Text(record.title)
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 9) {
                if !record.sourceType.isEmpty { Text(record.sourceType.capitalized) }
                Text("\(record.wordCount.formatted()) words")
                if let sourceURL {
                    Link("Open source", destination: sourceURL)
                } else if !record.source.isEmpty {
                    Text(record.source).lineLimit(1).help(record.source)
                }
                Spacer(minLength: 8)
                readerActions
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background(LibraryColors.shelf)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var readingCard: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    tabPicker
                    Spacer(minLength: 8)
                    textTools
                }
                VStack(alignment: .leading, spacing: 7) {
                    tabPicker
                    textTools
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(LibraryColors.line).frame(height: 1)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .padding(8)
            }
            if let document, let part = tab.part {
                ReaderTextPane(document: document, highlights: highlights.filter { $0.part == part },
                               jump: jump, onSelection: { selection = $0 }, onTimestamp: openTimestamp,
                               onHighlight: { saveHighlight($0, in: document, part: part) })
                    .id(tab)
                    .frame(maxWidth: tab == .transcript ? 688 : 766)
                    .frame(maxWidth: .infinity)
            } else {
                highlightList
            }
        }
        .doggoWindowCard()
    }

    private var tabPicker: some View {
        Picker("Reading view", selection: Binding(get: { tab }, set: showTab)) {
            ForEach(ReaderTab.allCases, id: \.self) { page in
                Text(page == .highlights && !highlights.isEmpty ? "Highlights \(highlights.count)" : page.rawValue)
                    .tag(page)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 288)
    }

    private var places: [ReaderLocation] {
        if tab == .summary { return document?.headings ?? [] }
        guard tab == .transcript, let transcript else { return [] }
        return record.chapters.compactMap { chapter in
            guard let time = TranscriptTimecode.seconds(from: chapter.start), let offset = transcript.location(at: time) else {
                return nil
            }
            return ReaderLocation(title: "\(chapter.start)  \(chapter.title)", offset: offset)
        }
    }

    @ViewBuilder
    private var textTools: some View {
        if let document, let part = tab.part {
            HStack(spacing: 7) {
                if !places.isEmpty {
                    Menu("Jump to") {
                        ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                            Button(place.title) { jump = ReaderJump(offset: place.offset) }
                        }
                    }
                    .fixedSize()
                }
                Button {
                    if let selection { saveHighlight(selection, in: document, part: part) }
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .disabled(selection == nil)
                .help("Select text to save a highlight")
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }

    private var readerActions: some View {
        let related = store.records.filter { $0.id != record.id && $0.category == record.category }.prefix(4)
        return Menu {
            Button("Change folder…") { changingFolder = true }
            if !record.todos.isEmpty {
                Menu("To-dos") {
                    ForEach(record.todos, id: \.self) { todo in
                        Button {
                            var updated = record
                            if updated.doneTodos.contains(todo) { updated.doneTodos.removeAll { $0 == todo } }
                            else { updated.doneTodos.append(todo) }
                            if !store.update(updated) { problem = "Doggo couldn’t update this to-do." }
                        } label: {
                            Label(todo, systemImage: record.doneTodos.contains(todo) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            if !related.isEmpty {
                Menu("Related transcripts") {
                    ForEach(related) { other in Button(other.title) { onSelect(other.id) } }
                }
            }
            Button("Delete transcript…", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Transcript actions")
    }

    @ViewBuilder
    private var highlightList: some View {
        if highlights.isEmpty {
            ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                   description: Text("Select text in the summary or transcript and click Highlight."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(highlights) { highlight in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                showHighlight(highlight)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(highlight.part.rawValue.capitalized)
                                        .font(.caption.weight(.semibold)).foregroundStyle(LibraryColors.accent)
                                    Text(highlight.text).font(.system(size: 15, design: .serif))
                                        .multilineTextAlignment(.leading).lineLimit(5)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                if store.removeHighlight(highlight.id) { highlights.removeAll { $0.id == highlight.id } }
                                else { problem = "Doggo couldn’t remove the highlight." }
                            } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Remove highlight")
                        }
                        .padding(13)
                        .background(LibraryColors.shelf, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(22)
                .frame(maxWidth: 766)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func showTab(_ page: ReaderTab) {
        if page == .transcript, transcript == nil {
            transcript = .transcript(store.rawText(for: record.id), chapters: record.chapters)
        }
        tab = page
        selection = nil
        jump = nil
        problem = nil
    }

    private func openTimestamp(_ seconds: Int) {
        showTab(.transcript)
        if let offset = transcript?.location(at: seconds) { jump = ReaderJump(offset: offset) }
    }

    private func showHighlight(_ highlight: TranscriptHighlight) {
        showTab(highlight.part == .summary ? .summary : .transcript)
        if let document,
           let offset = document.range(of: highlight)?.location ?? document.previousLayout?.timecodeLocation(for: highlight) {
            jump = ReaderJump(offset: offset)
        } else {
            problem = "This selection has moved. You can still read the saved highlight."
        }
    }

    private func saveHighlight(_ range: NSRange, in document: ReaderDocument, part: TranscriptText) {
        guard let text = document.selection(at: range), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if highlights.contains(where: { $0.part == part && $0.range == range && $0.text == text }) { return }
        let mark = TranscriptHighlight(part: part, range: range, text: text)
        if store.addHighlight(mark, to: record.id) {
            highlights = store.highlights(for: record.id)
            problem = nil
        } else {
            problem = "Doggo couldn’t save the highlight. Try again."
        }
    }
}

private struct ReaderTextPane: NSViewRepresentable {
    let document: ReaderDocument
    let highlights: [TranscriptHighlight]
    let jump: ReaderJump?
    let onSelection: (NSRange?) -> Void
    let onTimestamp: (Int) -> Void
    let onHighlight: (NSRange) -> Void

    private static let markColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.38, green: 0.30, blue: 0.16, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.88, blue: 0.59, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReadingScrollView {
        let scroll = ReadingScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = ReadingTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.delegate = context.coordinator
        text.setAccessibilityLabel("Transcript reading text")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: ReadingScrollView, context: Context) {
        guard let text = scroll.documentView as? ReadingTextView else { return }
        let coordinator = context.coordinator
        coordinator.onSelection = onSelection
        coordinator.onTimestamp = onTimestamp
        text.onHighlight = onHighlight

        let sameText = coordinator.previous?.isEqual(to: document.body) ?? false
        if !sameText || coordinator.highlights != highlights {
            let selected = sameText ? text.selectedRange() : NSRange(location: 0, length: 0)
            let origin = scroll.contentView.bounds.origin
            let styled = NSMutableAttributedString(attributedString: document.body)
            for highlight in highlights {
                if let range = document.range(of: highlight) {
                    styled.addAttribute(.backgroundColor, value: Self.markColor, range: range)
                }
            }
            coordinator.updating = true
            text.textStorage?.setAttributedString(styled)
            text.setSelectedRange(selected)
            if sameText { scroll.contentView.scroll(to: origin) }
            coordinator.updating = false
            coordinator.previous = document.body
            coordinator.highlights = highlights
        }

        if let jump, coordinator.lastJump != jump.id {
            coordinator.lastJump = jump.id
            scroll.jump(to: jump.offset)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var previous: NSAttributedString?
        var highlights: [TranscriptHighlight] = []
        var lastJump: UUID?
        var updating = false
        var onSelection: ((NSRange?) -> Void)?
        var onTimestamp: ((Int) -> Void)?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            let range = text.selectedRange()
            onSelection?(range.length == 0 ? nil : range)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "doggo-transcript",
                  let seconds = Int(url.lastPathComponent) else { return false }
            onTimestamp?(seconds)
            return true
        }
    }
}

private final class ReadingScrollView: NSScrollView {
    private var pendingJump: Int?

    func jump(to offset: Int) {
        pendingJump = offset
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Switching to the transcript can create this view before it has a viewport.
        guard contentView.bounds.width > 0, contentView.bounds.height > 0,
              let offset = pendingJump, let text = documentView as? ReadingTextView else { return }
        pendingJump = nil
        text.jump(to: offset)
    }
}

private final class ReadingTextView: NSTextView {
    var onHighlight: ((NSRange) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard selectedRange().length > 0 else { return menu }
        let withHighlight = menu ?? NSMenu()
        let action = NSMenuItem(title: "Highlight", action: #selector(highlightSelectedText), keyEquivalent: "")
        action.target = self
        withHighlight.insertItem(action, at: 0)
        return withHighlight
    }

    @objc private func highlightSelectedText() { onHighlight?(selectedRange()) }

    func jump(to offset: Int) {
        guard offset >= 0, offset < (string as NSString).length, let scroll = enclosingScrollView,
              let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = max(0, line.minY + textContainerOrigin.y - 12)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

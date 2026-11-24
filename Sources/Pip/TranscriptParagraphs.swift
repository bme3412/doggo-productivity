import Foundation

struct TranscriptProjection {
    struct Span {
        let original: NSRange
        let offset: Int
    }

    let original: NSString
    let spans: [Span]
    let timecodes: [Span]

    func range(of highlight: TranscriptHighlight) -> NSRange? {
        guard matches(highlight) else { return nil }
        var start: Int?
        var end: Int?
        for span in spans {
            let overlap = NSIntersectionRange(span.original, highlight.range)
            guard overlap.length > 0 else { continue }
            let offset = span.offset + overlap.location - span.original.location
            if start == nil { start = offset }
            end = offset + overlap.length
        }
        guard let start, let end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func timecodeLocation(for highlight: TranscriptHighlight) -> Int? {
        guard matches(highlight) else { return nil }
        return timecodes.first { NSIntersectionRange($0.original, highlight.range).length > 0 }?.offset
    }

    private func matches(_ highlight: TranscriptHighlight) -> Bool {
        let range = highlight.range
        return range.location >= 0 && range.location < original.length && range.length > 0
            && range.length <= original.length - range.location && original.substring(with: range) == highlight.text
    }
}

struct TranscriptParagraphs {
    struct Block {
        enum Style { case prose, heading, timecode }
        let text: String
        let style: Style
    }

    let blocks: [Block]
    let cues: [(seconds: Int, offset: Int)]
    let projection: TranscriptProjection?

    private struct Marker {
        let prefix: NSRange
        let time: NSRange
        let seconds: Int
    }

    private static let pastedChapter = try! NSRegularExpression(pattern: #"\bChapter [0-9]+:[ \t]*([^\r\n]+)$"#)
    private static let sentenceBreak = try! NSRegularExpression(
        pattern: #"[.!?。！？]+["”’')\]]*(?=\s+["“‘']?\p{Lu})"#
    )

    init(source: String, chapters: [Chapter]) {
        // This was the string displayed before the reading layout changed. Saved selections use its UTF-16 offsets.
        let previous = TranscriptTimecode.copied.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "\n$1  "
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let original = previous as NSString
        let extent = NSRange(location: 0, length: original.length)
        let markers = TranscriptTimecode.line.matches(in: previous, range: extent).compactMap { match -> Marker? in
            let time = match.range(at: 1)
            guard let seconds = TranscriptTimecode.seconds(from: original.substring(with: time)) else { return nil }
            return Marker(prefix: match.range, time: time, seconds: seconds)
        }

        var writer = Writer(original: original)
        if markers.count > 1 {
            let headings = chapters.reduce(into: [Int: String]()) { names, chapter in
                if let seconds = TranscriptTimecode.seconds(from: chapter.start) { names[seconds] = chapter.title }
            }
            writer.writeCaptions(previous, markers: markers, chapterTitles: headings,
                                 copied: TranscriptTimecode.hasCopiedCaptions(source))
        } else {
            writer.writePlain(previous)
            if let marker = markers.first {
                writer.cues = [(marker.seconds, marker.time.location)]
            }
        }
        blocks = writer.blocks
        cues = writer.cues
        projection = writer.spans.isEmpty ? nil
            : TranscriptProjection(original: original, spans: writer.spans, timecodes: writer.oldTimecodes)
    }

    private struct Writer {
        let original: NSString
        var blocks: [Block] = []
        var cues: [(seconds: Int, offset: Int)] = []
        var spans: [TranscriptProjection.Span] = []
        var oldTimecodes: [TranscriptProjection.Span] = []
        var offset = 0

        mutating func append(_ text: String, style: Block.Style) {
            guard !text.isEmpty else { return }
            blocks.append(Block(text: text, style: style))
            offset += text.utf16.count
        }

        mutating func copy(_ range: NSRange, style: Block.Style, flatten: Bool = false) {
            guard range.length > 0 else { return }
            let source = original.substring(with: range)
            let text = flatten
                ? source.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
                : source
            spans.append(TranscriptProjection.Span(original: range, offset: offset))
            append(text, style: style)
        }

        func trimmed(_ range: NSRange) -> NSRange {
            let content = CharacterSet.whitespacesAndNewlines.inverted
            let start = original.rangeOfCharacter(from: content, options: [], range: range)
            guard start.location != NSNotFound else { return NSRange(location: range.location, length: 0) }
            let end = original.rangeOfCharacter(from: content, options: .backwards, range: range)
            return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        }

        func bodyAndHeading(_ range: NSRange, in previous: String, copied: Bool) -> (NSRange, NSRange?) {
            let text = trimmed(range)
            guard copied, let match = TranscriptParagraphs.pastedChapter.firstMatch(in: previous, range: text),
                  match.range(at: 1).length <= 150 else { return (text, nil) }
            return (trimmed(NSRange(location: text.location, length: match.range.location - text.location)),
                    trimmed(match.range(at: 1)))
        }

        mutating func writeCaptions(_ previous: String, markers: [Marker], chapterTitles: [Int: String], copied: Bool) {
            let first = markers[0]
            let (introduction, introHeading) = bodyAndHeading(NSRange(location: 0, length: first.prefix.location),
                                                              in: previous, copied: copied)
            if introduction.length > 0 {
                copy(introduction, style: .prose)
                append("\n", style: .prose)
            }
            var pendingHeading = introHeading
            var paragraphStart = first.seconds
            var paragraphLength = 0
            var sentenceEnded = true

            for (index, marker) in markers.enumerated() {
                let start = NSMaxRange(marker.prefix)
                let end = index + 1 < markers.count ? markers[index + 1].prefix.location : original.length
                let (content, followingHeading) = bodyAndHeading(NSRange(location: start, length: end - start),
                                                                 in: previous, copied: copied)
                let chapter = chapterTitles[marker.seconds]
                let age = marker.seconds - paragraphStart
                let speakerChange = content.length >= 2 && original.substring(with: NSRange(location: content.location, length: 2)) == ">>"
                let startsParagraph = paragraphLength == 0 || pendingHeading != nil || chapter != nil || speakerChange
                    || (age >= 43 && sentenceEnded) || age >= 100 || paragraphLength >= 1_100

                if startsParagraph {
                    if paragraphLength > 0 { append("\n", style: .prose) }
                    if let heading = pendingHeading {
                        copy(heading, style: .heading)
                        append("\n", style: .heading)
                    } else if let chapter, !copied {
                        append(chapter + "\n", style: .heading)
                    }
                    cues.append((marker.seconds, offset))
                    copy(marker.time, style: .timecode)
                    append("\n", style: .timecode)
                    paragraphStart = marker.seconds
                    paragraphLength = 0
                } else {
                    append(" ", style: .prose)
                    cues.append((marker.seconds, offset))
                }
                oldTimecodes.append(.init(original: marker.time, offset: cues.last?.offset ?? offset))

                // Let a paragraph end inside a caption when the next sentence starts there.
                if !startsParagraph, paragraphLength >= 490 || age >= 40,
                   let boundary = TranscriptParagraphs.sentenceBreak.firstMatch(in: previous, range: content) {
                    let split = NSMaxRange(boundary.range)
                    let tail = trimmed(NSRange(location: split, length: NSMaxRange(content) - split))
                    copy(NSRange(location: content.location, length: split - content.location), style: .prose, flatten: true)
                    append("\n", style: .prose)
                    append(original.substring(with: marker.time) + "\n", style: .timecode)
                    copy(tail, style: .prose, flatten: true)
                    paragraphStart = marker.seconds
                    paragraphLength = tail.length
                } else {
                    copy(content, style: .prose, flatten: true)
                    paragraphLength += content.length
                }
                if content.length > 0 {
                    let last = original.character(at: NSMaxRange(content) - 1)
                    sentenceEnded = last == 46 || last == 63 || last == 33
                }
                pendingHeading = followingHeading
            }
            if let pendingHeading {
                append("\n", style: .prose)
                copy(pendingHeading, style: .heading)
            }
        }

        mutating func writePlain(_ text: String) {
            let extent = NSRange(location: 0, length: original.length)
            guard original.length > 850, !text.contains("\n") else {
                copy(extent, style: .prose)
                return
            }
            var start = 0
            var ends: [Int] = []
            text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, range, _ in
                ends.append(NSMaxRange(NSRange(range, in: text)))
            }
            for end in ends where end - start >= 570 {
                copy(trimmed(NSRange(location: start, length: end - start)), style: .prose)
                if end < extent.length { append("\n", style: .prose) }
                start = end
            }
            copy(trimmed(NSRange(location: start, length: extent.length - start)), style: .prose)
        }
    }
}

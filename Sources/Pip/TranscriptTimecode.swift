import Foundation

enum TranscriptTimecode {
    // The copied accessibility label follows the visible YouTube timestamp.
    static let copied = try! NSRegularExpression(
        pattern: #"(?<![\d:])(\d{1,3}:\d{2}(?::\d{2})?)[ \t]*(?:\d+[ \t]+(?:hours?|minutes?|seconds?)(?:,[ \t]*)?){1,3}"#
    )
    static let line = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*\[?(\d{1,3}:\d{2}(?::\d{2})?)\]?(?=[ \t]|$)"#
    )

    static func hasCopiedCaptions(_ text: String) -> Bool {
        let prefix = String(text.prefix(6_000))
        return copied.numberOfMatches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) > 1
    }

    static func seconds(from time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard (2...3).contains(parts.count), values.count == parts.count,
              values.allSatisfy({ (0...999).contains($0) }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}

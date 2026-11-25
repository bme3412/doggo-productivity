import AppKit
import Combine
import EventKit
import Foundation

/// Native macOS Calendar bridge (reads & writes iCloud, Google, Exchange calendars signed into macOS).
@MainActor
final class CalendarSync: ObservableObject {
    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    struct SyncedEvent: Identifiable, Equatable {
        let id: String
        let eventIdentifier: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let calendarTitle: String
        let colorHex: UInt32
        let meetingURL: URL?
        let isEditable: Bool

        var timeLabel: String {
            if isAllDay { return "All day" }
            return startDate.formatted(date: .omitted, time: .shortened)
        }

        var durationMinutes: Int {
            max(0, Int(endDate.timeIntervalSince(startDate) / 60))
        }
    }

    struct DayShape {
        let eventCount: Int
        let bestBlockStart: Date?
        let bestBlockEnd: Date?

        var bestBlockMinutes: Int {
            guard let start = bestBlockStart, let end = bestBlockEnd else { return 0 }
            return max(0, Int(end.timeIntervalSince(start) / 60))
        }
    }

    @Published private(set) var status: Status = .notDetermined
    @Published private(set) var events: [SyncedEvent] = []
    @Published private(set) var lastError: String?

    private let store = EKEventStore()
    private var loadedMonth = Date()
    private var storeObserver: AnyCancellable?

    var isAuthorized: Bool { status == .authorized }

    init() {
        refreshAuthorizationStatus()
        storeObserver = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
        if isAuthorized {
            reload()
        }
    }

    func refreshAuthorizationStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            status = .authorized
        case .notDetermined:
            status = .notDetermined
        case .denied, .restricted, .writeOnly:
            status = .denied
        @unknown default:
            status = .denied
        }
    }

    func requestAccess() {
        lastError = nil
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                await MainActor.run {
                    self.refreshAuthorizationStatus()
                    if granted || self.isAuthorized {
                        self.reload()
                    }
                }
            } catch {
                await MainActor.run {
                    self.refreshAuthorizationStatus()
                    self.lastError = "Couldn’t connect to Calendar."
                }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func loadMonth(_ month: Date) {
        loadedMonth = month
        guard isAuthorized else { return }
        reload()
    }

    func reload() {
        guard isAuthorized else {
            events = []
            return
        }
        let calendar = Calendar.current
        let today = Date()
        let anchorMin = min(today, loadedMonth)
        let anchorMax = max(today, loadedMonth)
        guard let start = calendar.date(byAdding: .month, value: -1, to: calendar.startOfDay(for: anchorMin)),
              let end = calendar.date(byAdding: .month, value: 2, to: calendar.startOfDay(for: anchorMax)) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let raw = store.events(matching: predicate)
        events = raw
            .filter { $0.status != .canceled }
            .map { event in
                let id = "\(event.eventIdentifier ?? UUID().uuidString)-\(Int(event.startDate.timeIntervalSince1970))"
                return SyncedEvent(
                    id: id,
                    eventIdentifier: event.eventIdentifier ?? "",
                    title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled event" : event.title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar?.title ?? "Calendar",
                    colorHex: Self.hexColor(from: event.calendar?.cgColor),
                    meetingURL: Self.extractMeetingURL(from: event),
                    isEditable: event.calendar?.allowsContentModifications ?? false
                )
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
    }

    func events(on day: Date) -> [SyncedEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { event in
            if event.isAllDay {
                return calendar.isDate(event.startDate, inSameDayAs: dayStart)
                    || (event.startDate < dayEnd && event.endDate > dayStart)
            }
            return event.startDate < dayEnd && event.endDate > dayStart
        }
    }

    func hasEvent(on day: Date) -> Bool {
        !events(on: day).isEmpty
    }

    func dotColorHex(on day: Date) -> UInt32? {
        events(on: day).first?.colorHex
    }

    /// Saves an event into the user's default macOS calendar (syncs to Google/iCloud).
    /// Supports optional natural time like "3pm Dentist", "10:30am Coffee", or "14:00 Review".
    @discardableResult
    func addEvent(_ raw: String, on day: Date) -> Bool {
        guard isAuthorized,
              let targetCalendar = store.defaultCalendarForNewEvents,
              targetCalendar.allowsContentModifications else { return false }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let parsed = Self.parseTitleAndTime(trimmed, on: day)
        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar
        event.title = parsed.title
        if let start = parsed.start {
            event.isAllDay = false
            event.startDate = start
            event.endDate = start.addingTimeInterval(60 * 60)
        } else {
            let dayStart = Calendar.current.startOfDay(for: day)
            event.isAllDay = true
            event.startDate = dayStart
            event.endDate = dayStart
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            reload()
            return true
        } catch {
            lastError = "Couldn’t save to Calendar."
            return false
        }
    }

    @discardableResult
    func removeEvent(_ synced: SyncedEvent) -> Bool {
        guard isAuthorized, synced.isEditable,
              let event = store.event(withIdentifier: synced.eventIdentifier) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            reload()
            return true
        } catch {
            lastError = "Couldn’t remove from Calendar."
            return false
        }
    }

    // MARK: - Proactive assistant queries

    /// Timed event starting in 1...8 minutes.
    func upcomingRunwayEvent(at now: Date) -> SyncedEvent? {
        guard isAuthorized else { return nil }
        return events(on: now).first { event in
            guard !event.isAllDay else { return false }
            let until = event.startDate.timeIntervalSince(now)
            return until >= 60 && until <= 8 * 60
        }
    }

    /// Timed event (>= 15 min) that finished 1...5 minutes ago.
    func recentlyEndedEvent(at now: Date) -> SyncedEvent? {
        guard isAuthorized else { return nil }
        return events(on: now).last { event in
            guard !event.isAllDay, event.durationMinutes >= 15 else { return false }
            let sinceEnd = now.timeIntervalSince(event.endDate)
            return sinceEnd >= 60 && sinceEnd <= 5 * 60
        }
    }

    /// Summarizes today's timed events and finds the longest open focus block before 6 PM.
    func dayShape(at now: Date) -> DayShape? {
        guard isAuthorized else { return nil }
        let calendar = Calendar.current
        let todayTimed = events(on: now).filter { !$0.isAllDay }
        guard !todayTimed.isEmpty else { return nil }

        let dayStart = calendar.startOfDay(for: now)
        let workStart = max(now, calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? now)
        let workEnd = calendar.date(byAdding: .hour, value: 18, to: dayStart) ?? workStart

        var bestStart: Date?
        var bestEnd: Date?
        var cursor = workStart

        if workStart < workEnd {
            let busy = todayTimed
                .map { (max($0.startDate, workStart), min($0.endDate, workEnd)) }
                .filter { $0.0 < $0.1 }
                .sorted { $0.0 < $1.0 }

            for (s, e) in busy {
                if s > cursor {
                    let gap = s.timeIntervalSince(cursor)
                    let best = (bestEnd?.timeIntervalSince(bestStart ?? cursor) ?? 0)
                    if gap > best { bestStart = cursor; bestEnd = s }
                }
                if e > cursor { cursor = e }
            }
            if workEnd > cursor {
                let gap = workEnd.timeIntervalSince(cursor)
                let best = (bestEnd?.timeIntervalSince(bestStart ?? cursor) ?? 0)
                if gap > best { bestStart = cursor; bestEnd = workEnd }
            }
        }

        return DayShape(eventCount: todayTimed.count, bestBlockStart: bestStart, bestBlockEnd: bestEnd)
    }

    // MARK: - Helpers

    private static func hexColor(from cgColor: CGColor?) -> UInt32 {
        guard let color = cgColor.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else {
            return 0x3C776B
        }
        let r = UInt32(max(0, min(255, (color.redComponent * 255).rounded())))
        let g = UInt32(max(0, min(255, (color.greenComponent * 255).rounded())))
        let b = UInt32(max(0, min(255, (color.blueComponent * 255).rounded())))
        return (r << 16) | (g << 8) | b
    }

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "facetime.apple.com", "cal.com", "around.co", "huddle"
    ]

    private static func extractMeetingURL(from event: EKEvent) -> URL? {
        var candidates: [URL] = []
        if let url = event.url, ["http", "https"].contains(url.scheme?.lowercased()) {
            candidates.append(url)
        }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()) {
                    candidates.append(url)
                }
            }
        }
        if let video = candidates.first(where: { url in
            let host = (url.host ?? "").lowercased()
            return meetingHosts.contains { host.contains($0) }
        }) {
            return video
        }
        return event.url
    }

    /// Parses optional leading time like "3pm Dentist", "10:30 am Standup", or "14:00 Review".
    static func parseTitleAndTime(_ input: String, on day: Date) -> (title: String, start: Date?) {
        let pattern = #"^(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b[\s\-–:]*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (input, nil)
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              let hourRange = Range(match.range(at: 1), in: input),
              let titleRange = Range(match.range(at: 4), in: input),
              var hour = Int(input[hourRange]) else {
            return (input, nil)
        }

        let minute: Int
        if let minRange = Range(match.range(at: 2), in: input), let m = Int(input[minRange]) {
            minute = m
        } else {
            minute = 0
        }

        let meridiem = Range(match.range(at: 3), in: input).map { input[$0].lowercased() }
        // Require either am/pm or an explicit colon (e.g. "14:00") so "3 apples" isn't parsed as 3:00.
        guard meridiem != nil || match.range(at: 2).location != NSNotFound else {
            return (input, nil)
        }

        if let meridiem {
            guard hour >= 1 && hour <= 12 else { return (input, nil) }
            if meridiem == "pm" && hour < 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
        } else {
            guard hour >= 0 && hour <= 23 else { return (input, nil) }
        }
        guard minute >= 0 && minute <= 59 else { return (input, nil) }

        let title = input[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (input, nil) }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        return (title, Calendar.current.date(from: comps))
    }
}

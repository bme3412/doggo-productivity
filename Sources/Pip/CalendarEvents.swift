import Foundation
import Combine

/// Events saved against a calendar day, stored beside the other Doggo data.
@MainActor
final class CalendarEvents: ObservableObject {
    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var day: String
        var title: String
    }

    private struct Saved: Codable {
        var events: [Event]
    }

    static let limitPerDay = 8

    @Published private(set) var events: [Event] = []
    @Published var selected = Calendar.current.startOfDay(for: Date())

    private let file: URL
    private var canWrite = true

    init(file: URL = Prefs.supportDirectory.appendingPathComponent("calendar-events.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            events = saved.events
        }
    }

    func events(on day: Date) -> [Event] {
        let key = ActivityTracker.dayString(day)
        return events.filter { $0.day == key }
    }

    func hasEvent(on day: Date) -> Bool {
        let key = ActivityTracker.dayString(day)
        return events.contains { $0.day == key }
    }

    func add(_ title: String, on day: Date) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, events(on: day).count < Self.limitPerDay else { return }
        events.append(Event(day: ActivityTracker.dayString(day), title: title))
        save()
    }

    func remove(_ id: UUID) {
        guard events.contains(where: { $0.id == id }) else { return }
        events.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard canWrite else { return }
        do {
            try JSONEncoder().encode(Saved(events: events)).write(to: file, options: .atomic)
        } catch {
            canWrite = false
        }
    }
}

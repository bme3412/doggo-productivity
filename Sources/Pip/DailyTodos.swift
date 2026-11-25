import Foundation
import Combine

/// Today's checklist, kept beside the dogs. Unfinished items carry into the next day.
@MainActor
final class DailyTodos: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var done = false
    }

    private struct Saved: Codable {
        var day: String
        var items: [Item]
    }

    static let limit = 12

    @Published private(set) var items: [Item] = []
    private let file: URL
    private var day: String
    private var canWrite = true

    init(file: URL = Prefs.supportDirectory.appendingPathComponent("daily-todos.json")) {
        self.file = file
        day = ActivityTracker.dayString(Date())
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            day = saved.day
            items = saved.items
        }
        rollIfNeeded()
    }

    func rollIfNeeded(now: Date = Date()) {
        let today = ActivityTracker.dayString(now)
        guard today != day else { return }
        day = today
        items = items.filter { !$0.done }
        save()
    }

    func add(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, items.count < Self.limit else { return }
        items.append(Item(title: title))
        save()
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].done.toggle()
        items = updated
        save()
    }

    private func save() {
        guard canWrite else { return }
        do {
            try JSONEncoder().encode(Saved(day: day, items: items)).write(to: file, options: .atomic)
        } catch {
            canWrite = false
        }
    }
}

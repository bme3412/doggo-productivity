import Foundation
import Combine

/// Today's checklist, kept beside the dogs. Unfinished items carry into the next day.
@MainActor
final class DailyTodos: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var done = false
        var pinned = false

        init(id: UUID = UUID(), title: String, done: Bool = false, pinned: Bool = false) {
            self.id = id
            self.title = title
            self.done = done
            self.pinned = pinned
        }

        private enum CodingKeys: String, CodingKey { case id, title, done, pinned }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            title = try c.decode(String.self, forKey: .title)
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    private struct Saved: Codable {
        var day: String
        var items: [Item]
    }

    static let limit = 20

    @Published private(set) var items: [Item] = []
    private let file: URL
    private var day: String
    private var canWrite = true

    var openCount: Int { items.filter { !$0.done }.count }
    var doneCount: Int { items.filter(\.done).count }

    /// Open pinned items first, then open items, then finished items.
    var orderedItems: [Item] {
        let pinned = items.filter { !$0.done && $0.pinned }
        let open = items.filter { !$0.done && !$0.pinned }
        let done = items.filter(\.done)
        return pinned + open + done
    }

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
        if updated[index].done { updated[index].pinned = false }
        items = updated
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].done else { return }
        var updated = items
        updated[index].pinned.toggle()
        items = updated
        save()
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    func clearDone() {
        guard items.contains(where: \.done) else { return }
        items.removeAll { $0.done }
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

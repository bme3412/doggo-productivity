import Combine
import Foundation

struct DogLook: Codable, Equatable, Sendable {
    enum Ears: String, CaseIterable, Codable, Sendable { case floppy, short, upright }
    enum Tail: String, CaseIterable, Codable, Sendable { case smooth, fluffy, short }
    enum Markings: String, CaseIterable, Codable, Sendable { case solid, patches, brindle }

    var coat: UInt32 = 0xB08262
    var markingsColor: UInt32 = 0x754E38
    var muzzle: UInt32 = 0x885D46
    var earColor: UInt32 = 0x754E38
    var ears: Ears = .floppy
    var tail: Tail = .smooth
    var markings: Markings = .solid
    var longMuzzle = false
    var chestPatch = false
    var collar: UInt32? = nil
    var harness: UInt32? = nil

    static func shade(_ rgb: UInt32, by amount: Double) -> UInt32 {
        func channel(_ shift: Int) -> UInt32 {
            let value = Double((rgb >> shift) & 255)
            let changed = amount >= 0 ? value + (255 - value) * amount : value * (1 + amount)
            return UInt32(min(255, max(0, changed.rounded())))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

struct DogProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var look: DogLook
    var referencePhoto: Data
}

enum DogArtwork: Equatable, Sendable {
    case classic, black, photo(DogLook)
}

struct DesktopDog: Identifiable, Sendable {
    let id: UUID
    let name: String
    let artwork: DogArtwork

    // Keep these IDs stable so desktop and guide selections survive a restart.
    static let classic = DesktopDog(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                    name: "Doggo", artwork: .classic)
    static let black = DesktopDog(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                  name: "Black dog", artwork: .black)
    static let builtIns = [classic, black]
}

@MainActor
final class DogAppearance: ObservableObject {
    nonisolated static let limit = 2

    private struct SavedAppearance: Codable {
        var profiles: [DogProfile] = []
        var visible = DesktopDog.builtIns.map(\.id)
        var guide: UUID?
    }

    @Published private var saved = SavedAppearance()
    @Published private(set) var error: String?
    private let file: URL
    private var canWrite = true

    init(file: URL = Prefs.supportDirectory.appendingPathComponent("my-dogs.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            saved = try JSONDecoder().decode(SavedAppearance.self, from: Data(contentsOf: file))
        } catch {
            canWrite = false
            self.error = "Doggo couldn’t read the saved dog profiles."
        }
    }

    var profiles: [DogProfile] { saved.profiles }
    var availableSlots: Int { max(0, Self.limit - profiles.count) }
    private var desktopDogs: [DesktopDog] {
        DesktopDog.builtIns + profiles.map { DesktopDog(id: $0.id, name: $0.name, artwork: .photo($0.look)) }
    }
    var visibleDogs: [DesktopDog] {
        let dogs = desktopDogs
        let visible = saved.visible.compactMap { id in dogs.first(where: { $0.id == id }) }
        return visible.isEmpty ? [.classic] : visible
    }
    var guide: DesktopDog {
        let dogs = visibleDogs
        return dogs.first(where: { $0.id == saved.guide }) ?? dogs.first ?? .classic
    }

    @discardableResult
    func add(_ new: [DogProfile]) -> Bool {
        let ids = new.map(\.id)
        guard !new.isEmpty, new.count <= availableSlots,
              Set(ids).count == ids.count, Set(ids).isDisjoint(with: desktopDogs.map(\.id)) else { return false }
        var update = saved
        update.profiles.append(contentsOf: new)
        if saved.profiles.isEmpty {
            update.visible = ids
            update.guide = ids.first
        }
        return commit(update)
    }

    @discardableResult
    func save(_ profile: DogProfile) -> Bool {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        var update = saved
        update.profiles[index] = profile
        return commit(update)
    }

    @discardableResult
    func show(_ ids: [UUID]) -> Bool {
        let existingIDs = desktopDogs.map(\.id)
        guard ids.count <= Self.limit, Set(ids).count == ids.count,
              ids.allSatisfy(existingIDs.contains) else { return false }
        var update = saved
        update.visible = ids
        if update.guide.map(ids.contains) != true {
            update.guide = ids.first
        }
        return commit(update)
    }

    func chooseGuide(_ id: UUID) {
        guard id != guide.id, visibleDogs.contains(where: { $0.id == id }) else { return }
        var update = saved
        update.guide = id
        _ = commit(update)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        var update = saved
        update.profiles.removeAll { $0.id == id }
        update.visible.removeAll { $0 == id }
        if update.guide == id { update.guide = update.visible.first }
        return commit(update)
    }

    private func commit(_ update: SavedAppearance) -> Bool {
        guard canWrite else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(update).write(to: file, options: .atomic)
            saved = update
            error = nil
            return true
        } catch {
            self.error = "Doggo couldn’t save the dog profiles. Try again."
            return false
        }
    }
}

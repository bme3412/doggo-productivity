import Foundation
import Security

enum Persona: String, CaseIterable, Identifiable {
    case archivist, warden, coach
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var next: Self {
        switch self {
        case .archivist: return .warden
        case .warden: return .coach
        case .coach: return .archivist
        }
    }
}

/// Strictness levels for the Warden, expressed as dog behaviour.
enum Strictness: Int, CaseIterable, Identifiable {
    case nap = 0, sigh, fetch, bark
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .nap: return "Nap"
        case .sigh: return "Sigh"
        case .fetch: return "Fetch"
        case .bark: return "Bark"
        }
    }
    var explanation: String {
        switch self {
        case .nap: return "Keeps Warden quiet and still tracks screen time."
        case .sigh: return "Sighs at you when a distraction streak hits the sigh mark."
        case .fetch: return "Sighs, then wants to play fetch at the fetch mark."
        case .bark: return "Sighs, fetch, then barks and closes the tab at the bark mark."
        }
    }
}

/// Thin wrapper over UserDefaults so every setting lives in one place.
enum Prefs {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "persona": Persona.warden.rawValue,
            "level": Strictness.fetch.rawValue,
            "sighMinutes": 15,
            "fetchMinutes": 20,
            "barkMinutes": 30,
            "minutesPerMile": 10.0,
            "claudeModel": "claude-sonnet-5-5",
            "distracting": [
                "reddit.com", "x.com", "twitter.com", "youtube.com", "facebook.com",
                "instagram.com", "tiktok.com", "news.ycombinator.com"
            ]
        ])
    }

    static var persona: Persona {
        get { Persona(rawValue: d.string(forKey: "persona") ?? "") ?? .warden }
        set { d.set(newValue.rawValue, forKey: "persona") }
    }
    static var level: Strictness {
        get { Strictness(rawValue: d.integer(forKey: "level")) ?? .fetch }
        set { d.set(newValue.rawValue, forKey: "level") }
    }
    static var sighMinutes: Int {
        get { max(1, d.integer(forKey: "sighMinutes")) }
        set { d.set(newValue, forKey: "sighMinutes") }
    }
    static var fetchMinutes: Int {
        get { max(1, d.integer(forKey: "fetchMinutes")) }
        set { d.set(newValue, forKey: "fetchMinutes") }
    }
    static var barkMinutes: Int {
        get { max(1, d.integer(forKey: "barkMinutes")) }
        set { d.set(newValue, forKey: "barkMinutes") }
    }
    static var minutesPerMile: Double {
        get { max(4, d.double(forKey: "minutesPerMile")) }
        set { d.set(newValue, forKey: "minutesPerMile") }
    }
    static var claudeModel: String {
        get { d.string(forKey: "claudeModel") ?? "claude-sonnet-5-5" }
        set { d.set(newValue, forKey: "claudeModel") }
    }
    static var distractingDomains: [String] {
        get { d.stringArray(forKey: "distracting") ?? [] }
        set { d.set(newValue, forKey: "distracting") }
    }

    static func isDistracting(_ host: String) -> Bool {
        distractingDomains.contains { entry in
            let value = entry.lowercased()
            let domain = value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    static var focusGoals: [FocusGoal] {
        get {
            guard let data = d.data(forKey: "focusGoals") else { return [] }
            return (try? JSONDecoder().decode([FocusGoal].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "focusGoals") }
    }

    static var walkStart: Date? {
        get { d.object(forKey: "walkStart") as? Date }
        set { d.set(newValue, forKey: "walkStart") }
    }

    static var bestFocusStreak: Int {
        get { d.integer(forKey: "bestFocusStreak") }
        set { d.set(newValue, forKey: "bestFocusStreak") }
    }

    static var accessory: Accessory {
        get { Accessory(rawValue: d.string(forKey: "accessory") ?? "") ?? .classic }
        set { d.set(newValue.rawValue, forKey: "accessory") }
    }

    static var lastGreetingDay: String? {
        get { d.string(forKey: "lastGreetingDay") }
        set { d.set(newValue, forKey: "lastGreetingDay") }
    }

    static var lastBedtimeEvening: String? {
        get { d.string(forKey: "lastBedtimeEvening") }
        set { d.set(newValue, forKey: "lastBedtimeEvening") }
    }

    static var lastReportWeek: String? {
        get { d.string(forKey: "lastReportWeek") }
        set { d.set(newValue, forKey: "lastReportWeek") }
    }

    /// API key: Keychain first, then the ANTHROPIC_API_KEY environment variable.
    static var apiKey: String? {
        if let k = Keychain.get(account: "anthropic"), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Share the existing library and activity history across the app rename.
        let dir = base.appendingPathComponent("Pip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Keychain {
    static let service = "com.brendan.pip"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

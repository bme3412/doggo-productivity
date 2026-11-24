import Foundation

struct FocusStats: Codable {
    static let dailyTarget: TimeInterval = 25 * 60

    var focused: TimeInterval = 0
    var distracted: TimeInterval = 0
    var longestStretch: TimeInterval = 0

    var metDailyTarget: Bool { focused >= Self.dailyTarget }
}

struct FocusGoal: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var units = ""
    var minutesPerUnit = 20

    func equivalent(for seconds: TimeInterval) -> String? {
        guard !name.isEmpty, !units.isEmpty, minutesPerUnit > 0 else { return nil }
        let quantity = seconds / (Double(minutesPerUnit) * 60)
        guard quantity >= 0.1 else { return nil }
        return "\(quantity.formatted(.number.precision(.fractionLength(0...1)))) \(units)"
    }
}

struct FocusWalk: Equatable {
    static let duration: TimeInterval = 25 * 60
    let start: Date

    var end: Date { start.addingTimeInterval(Self.duration) }

    func remaining(at date: Date) -> TimeInterval {
        min(Self.duration, max(0, end.timeIntervalSince(date)))
    }
}

enum Accessory: String, CaseIterable, Identifiable {
    case classic, trailBandana, brassTag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic bandana"
        case .trailBandana: return "Trail bandana"
        case .brassTag: return "Brass collar tag"
        }
    }

    var requiredDays: Int {
        switch self {
        case .classic: return 0
        case .trailBandana: return 7
        case .brassTag: return 14
        }
    }
}

enum WeeklyTemperament: Equatable {
    case steady, happy, mopey

    init(days: [DayStats]) {
        let observed = days.compactMap(\.focus).filter { $0.focused + $0.distracted >= 10 * 60 }
        let focused = observed.reduce(0) { $0 + $1.focused }
        let total = observed.reduce(0) { $0 + $1.focused + $1.distracted }
        guard observed.count >= 3, total >= 75 * 60 else { self = .steady; return }
        let share = focused / total
        if share >= 0.7 { self = .happy }
        else if share <= 0.45 { self = .mopey }
        else { self = .steady }
    }
}

struct WeeklyReport {
    let start: Date
    let through: Date
    let isPrevious: Bool
    let webSeconds: TimeInterval
    let priorWebSeconds: TimeInterval
    let distractingSeconds: TimeInterval
    let longestStretch: TimeInterval?
    let topSites: [SiteTime]

    init(start: Date, through: Date, isPrevious: Bool, days: [DayStats], prior: [DayStats],
         isDistracting: (String) -> Bool) {
        self.start = start
        self.through = through
        self.isPrevious = isPrevious
        webSeconds = days.reduce(0) { $0 + $1.webSeconds }
        priorWebSeconds = prior.reduce(0) { $0 + $1.webSeconds }
        distractingSeconds = days.reduce(0) { total, day in
            total + (day.focus?.distracted ?? day.sites.filter { isDistracting($0.key) }.values.reduce(0, +))
        }
        longestStretch = days.compactMap { $0.focus?.longestStretch }.max()
        topSites = SiteTime.totals(for: days)
    }
}

enum FocusCalendar {
    static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let daysSinceMonday = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    static func reportIsDue(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        return parts.weekday == 1 && (parts.hour ?? 0) >= 18
    }

    /// Before dawn, keep the previous evening's key so the bedtime cue fires once.
    static func evening(for date: Date, calendar: Calendar = .current) -> Date? {
        let hour = calendar.component(.hour, from: date)
        if hour >= 23 { return calendar.startOfDay(for: date) }
        if hour < 5 { return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) }
        return nil
    }
}

enum CoachReminder: CaseIterable {
    case posture, stretch, stand, water, walk

    private var offset: TimeInterval {
        switch self {
        case .posture: return 30 * 60
        case .stretch: return 45 * 60
        case .stand: return 60 * 60
        case .water: return 90 * 60
        case .walk: return 120 * 60
        }
    }

    static func latest(at deskTime: TimeInterval) -> (reminder: Self, time: TimeInterval)? {
        let cycle = Self.walk.offset
        let cycleStart = (deskTime / cycle).rounded(.down) * cycle
        let elapsed = deskTime - cycleStart
        if let reminder = allCases.last(where: { $0.offset <= elapsed }) {
            return (reminder, cycleStart + reminder.offset)
        }
        return cycleStart > 0 ? (.walk, cycleStart) : nil
    }

    static func untilNextStand(at deskTime: TimeInterval) -> TimeInterval {
        Self.stand.offset - deskTime.truncatingRemainder(dividingBy: Self.stand.offset)
    }
}

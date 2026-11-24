import AppKit
import CoreGraphics

/// One day of activity, saved as JSON in ~/Library/Application Support/Pip/activity/.
struct DayStats: Codable {
    var date: String
    var webSeconds: Double = 0
    var sites: [String: Double] = [:]      // host -> seconds
    var apps: [String: Double] = [:]       // app name -> seconds (non-browser)
    var nudges: Int = 0
    var snoozes: Int = 0
    var focus: FocusStats?                 // absent in activity files from earlier versions
    var siteVisits: [String: SiteVisits]?

    var siteCount: Int { sites.count }
    var topSites: [SiteTime] { SiteTime.totals(for: [self]) }

    mutating func recordWebsite(_ host: String, seconds: TimeInterval, startsVisit: Bool) {
        webSeconds += seconds
        sites[host, default: 0] += seconds
        var counted = siteVisits ?? [:]
        counted[host, default: SiteVisits()].seconds += seconds
        if startsVisit { counted[host, default: SiteVisits()].count += 1 }
        siteVisits = counted
    }
}

enum NudgeKind: String { case sigh, fetch, bark }

struct StreakEvent {
    let kind: NudgeKind
    let host: String
    let minutes: Int
}

struct ActivitySample {
    let date: Date
    let bundleID: String?
    let isActive: Bool
    let isDistracting: Bool
    let closedDistraction: Bool
}

@MainActor
final class ActivityTracker: ObservableObject {
    @Published private(set) var today: DayStats
    @Published private(set) var currentKey: String?
    @Published private(set) var streakSeconds: Double = 0
    @Published private(set) var streakHost: String?
    @Published private(set) var deskSeconds: TimeInterval = 0
    @Published private(set) var walk: FocusWalk?

    /// Called when a distraction streak crosses a threshold.
    var onStreak: ((StreakEvent) -> Void)?
    var onSample: ((ActivitySample) -> Void)?
    var onWalkFinished: (() -> Void)?

    private let interval: TimeInterval = 5
    private let idleCutoff: Double = 120       // seconds without input = away
    private let graceSeconds: Double = 60      // short detours don't reset a streak
    private var calmSeconds: Double = 0
    private var fired: Set<NudgeKind> = []
    private var snoozedUntil: Date?
    private var ticks = 0
    private var timer: Timer?
    private var walkTimer: Timer?
    private var lastTick: Date?
    private var focusStretch: TimeInterval = 0
    private var previousTab: BrowserBridge.Tab?
    private var siteSession = SiteVisitSession()
    private var pastDays: [String: DayStats] = [:]
    private var sessionActive = true

    init() {
        let now = Date()
        today = ActivityTracker.load(date: ActivityTracker.dayString(now))
        if let start = Prefs.walkStart, now < FocusWalk(start: start).end {
            walk = FocusWalk(start: start)
        } else if Prefs.walkStart != nil {
            Prefs.walkStart = nil
        }
    }

    func start() {
        timer?.invalidate()
        let sampler = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        timer = sampler
        RunLoop.main.add(sampler, forMode: .common)
        if walk != nil { startWalkTimer() }
    }

    func snooze(minutes: Int) {
        snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        today.snoozes += 1
        // When the snooze ends, the highest threshold reached fires again.
        fired.removeAll()
        save()
    }

    func countNudge() {
        today.nudges += 1
        save()
    }

    func resetStreak() {
        if streakSeconds != 0 { streakSeconds = 0 }
        if streakHost != nil { streakHost = nil }
        fired.removeAll()
        calmSeconds = 0
    }

    func resetDeskTime() {
        if deskSeconds != 0 { deskSeconds = 0 }
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        resetActivity()
        lastTick = nil
        if !active { save() }
    }

    func startWalk(at date: Date = Date()) {
        guard walk.map({ $0.remaining(at: date) == 0 }) ?? true else { return }
        resetStreak()
        Prefs.walkStart = date
        walk = FocusWalk(start: date)
        startWalkTimer()
        checkWalk(at: date)
    }

    func endWalk() {
        walkTimer?.invalidate()
        walkTimer = nil
        Prefs.walkStart = nil
        walk = nil
    }

    private func startWalkTimer() {
        walkTimer?.invalidate()
        let blocker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkWalk(at: Date()) }
        }
        blocker.tolerance = 0.1
        walkTimer = blocker
        RunLoop.main.add(blocker, forMode: .common)
    }

    private func checkWalk(at date: Date) {
        guard let walk else { return }
        if walk.remaining(at: date) == 0 {
            endWalk()
            onWalkFinished?()
            return
        }
        guard sessionActive, let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = BrowserBridge.browser(for: bundleID), let url = BrowserBridge.activeURL(browser),
              let host = BrowserBridge.host(from: url), Prefs.isDistracting(host), Date() < walk.end else { return }
        BrowserBridge.redirectActiveTab(browser, from: url)
    }

    func closeDistractingTab(on host: String) {
        if let tab = previousTab, tab.host == host,
           NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.bundleID).first != nil {
            previousTab = nil
            BrowserBridge.closeActiveTab(tab)
        }
        resetStreak()
    }

    // MARK: - Sampling

    private func resetActivity() {
        if currentKey != nil { currentKey = nil }
        previousTab = nil
        siteSession.leave()
        focusStretch = 0
        resetStreak()
        resetDeskTime()
    }

    private func tick() {
        let now = Date()
        if let lastTick, now.timeIntervalSince(lastTick) > 3 * interval { resetActivity() }
        lastTick = now
        let dayKey = ActivityTracker.dayString(now)
        if dayKey != today.date {
            save()
            pastDays[today.date] = today
            today = pastDays.removeValue(forKey: dayKey) ?? Self.load(date: dayKey)
            focusStretch = 0
            resetStreak()
        }

        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard sessionActive, idle <= idleCutoff, let app = NSWorkspace.shared.frontmostApplication else {
            resetActivity()
            onSample?(ActivitySample(date: now, bundleID: nil, isActive: false,
                                     isDistracting: false, closedDistraction: false))
            return
        }

        deskSeconds += interval
        let bundle = app.bundleIdentifier ?? ""
        let browser = BrowserBridge.browser(for: bundle)
        let tab = browser.flatMap { BrowserBridge.activeTab($0) }
        let url = tab?.url ?? browser.flatMap { BrowserBridge.activeURL($0) }
        let host = url.flatMap { BrowserBridge.host(from: $0) }
        let distracting = host.map(Prefs.isDistracting) ?? false
        let closedDistraction = userClosedDistraction(current: tab, bundle: bundle)
        if bundle != Bundle.main.bundleIdentifier || closedDistraction { previousTab = tab }

        if bundle != Bundle.main.bundleIdentifier {
            let key = host ?? app.localizedName ?? bundle
            if currentKey != key { currentKey = key }
            let hasFocusData = (browser == nil && !Self.isUntrackedBrowser(bundle)) || url != nil
            // A failed browser response can be temporary. A known non-web page or another app ends the visit.
            if host == nil, browser == nil || url?.isEmpty == false || tab?.count == 0 { siteSession.leave() }
            recordActivity(key: key, host: host, distracting: distracting, hasFocusData: hasFocusData, at: now)
        }

        if let host, distracting {
            calmSeconds = 0
            if walk == nil {
                streakSeconds += interval
                streakHost = host
                checkThresholds(host: host)
            }
        } else {
            calmSeconds += interval
            if calmSeconds >= graceSeconds { resetStreak() }
        }

        ticks += 1
        if ticks % 6 == 0 { save() }
        onSample?(ActivitySample(date: now, bundleID: bundle, isActive: true,
                                 isDistracting: distracting, closedDistraction: closedDistraction))
    }

    private func recordActivity(key: String, host: String?, distracting: Bool, hasFocusData: Bool, at date: Date) {
        var updated = today
        let startedVisit: Bool
        if let host {
            startedVisit = siteSession.observe(host, at: date, maximumGap: 3 * interval)
            updated.recordWebsite(host, seconds: interval, startsVisit: startedVisit)
        } else {
            startedVisit = false
            updated.apps[key, default: 0] += interval
        }

        let qualifiedBefore = updated.focus?.metDailyTarget ?? false
        if hasFocusData {
            var focus = updated.focus ?? FocusStats(distracted: today.sites.filter { Prefs.isDistracting($0.key) }.values.reduce(0, +))
            if distracting {
                focus.distracted += interval
                focusStretch = 0
            } else {
                focus.focused += interval
                focusStretch += interval
                focus.longestStretch = max(focus.longestStretch, focusStretch)
            }
            updated.focus = focus
        } else {
            focusStretch = 0
        }
        today = updated
        if startedVisit || (!qualifiedBefore && updated.focus?.metDailyTarget == true) { save() }
    }

    private func userClosedDistraction(current: BrowserBridge.Tab?, bundle: String) -> Bool {
        guard let previousTab, let host = previousTab.host, Prefs.isDistracting(host) else { return false }
        if let current, current.browser == previousTab.browser { return current.confirmsClosure(of: previousTab) }
        guard previousTab.browser.bundleID != bundle,
              !NSRunningApplication.runningApplications(withBundleIdentifier: previousTab.browser.bundleID).isEmpty else {
            return false
        }
        return BrowserBridge.activeTab(previousTab.browser)?.confirmsClosure(of: previousTab) ?? false
    }

    private static func isUntrackedBrowser(_ bundleID: String) -> Bool {
        ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.operasoftware.Opera",
         "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser"].contains(bundleID)
    }

    private func highestReached() -> NudgeKind? {
        let m = streakSeconds / 60
        if m >= Double(Prefs.barkMinutes) { return .bark }
        if m >= Double(Prefs.fetchMinutes) { return .fetch }
        if m >= Double(Prefs.sighMinutes) { return .sigh }
        return nil
    }

    private func checkThresholds(host: String) {
        if let until = snoozedUntil, Date() < until { return }
        let level = Prefs.level
        guard level != .nap, let reached = highestReached() else { return }

        let allowed: NudgeKind?
        switch (level, reached) {
        case (.sigh, _): allowed = .sigh
        case (.fetch, .bark): allowed = .fetch
        default: allowed = reached
        }
        guard let kind = allowed, !fired.contains(kind) else { return }
        fired.insert(kind)
        onStreak?(StreakEvent(kind: kind, host: host, minutes: Int(streakSeconds / 60)))
    }

    // MARK: - Focus history

    func recentDays(through date: Date, count: Int) -> [DayStats] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map { stats(for: $0) }
    }

    func allDays() -> [DayStats] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        let keys = files.compactMap { name -> String? in
            guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil else { return nil }
            return String(name.prefix(10))
        }
        return Set(keys + [today.date]).sorted(by: >).map { stats(forKey: $0) }
    }

    func focusStreak(through date: Date) -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: date)
        if stats(for: day).focus?.metDailyTarget != true {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while stats(for: day).focus?.metDailyTarget == true {
            count += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prior
        }
        return count
    }

    func weeklyReport(at date: Date, previous: Bool) -> WeeklyReport {
        let calendar = Calendar.current
        let current = FocusCalendar.weekStart(containing: date, calendar: calendar)
        let reportStart = previous ? (calendar.date(byAdding: .day, value: -7, to: current) ?? current) : current
        let lastDay = calendar.startOfDay(for: date)
        let daysSinceMonday = calendar.dateComponents([.day], from: current, to: lastDay).day ?? 0
        let length = previous ? 7 : min(7, max(1, daysSinceMonday + 1))
        let priorStart = calendar.date(byAdding: .day, value: -7, to: reportStart) ?? reportStart
        let days = (0..<length).compactMap { calendar.date(byAdding: .day, value: $0, to: reportStart) }
        let prior = (0..<length).compactMap { calendar.date(byAdding: .day, value: $0, to: priorStart) }
        return WeeklyReport(start: reportStart, through: days.last ?? reportStart, isPrevious: previous,
                            days: days.map { stats(for: $0) }, prior: prior.map { stats(for: $0) },
                            isDistracting: Prefs.isDistracting)
    }

    private func stats(for date: Date) -> DayStats {
        stats(forKey: Self.dayString(date))
    }

    private func stats(forKey key: String) -> DayStats {
        if today.date == key { return today }
        if let saved = pastDays[key] { return saved }
        let day = Self.load(date: key)
        pastDays[key] = day
        return day
    }

    // MARK: - Persistence

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static var folder: URL {
        let dir = Prefs.supportDirectory.appendingPathComponent("activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(date: String) -> DayStats {
        let url = folder.appendingPathComponent("\(date).json")
        if let data = try? Data(contentsOf: url),
           let stats = try? JSONDecoder().decode(DayStats.self, from: data) {
            return stats
        }
        return DayStats(date: date)
    }

    func save() {
        let url = ActivityTracker.folder.appendingPathComponent("\(today.date).json")
        if let data = try? JSONEncoder().encode(today) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum Format {
    static func websiteDuration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : duration(seconds)
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func miles(forSeconds seconds: Double) -> String {
        let miles = (seconds / 60) / Prefs.minutesPerMile
        return String(format: miles < 10 ? "%.1f" : "%.0f", miles)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(max(0, seconds)))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

import AppKit
import Combine

enum Mood: Hashable {
    case nap, sigh, fetch, bark, awake
    case stretch, excited, drowsy, happy, mopey, alert, coverEyes, walking, petting, wag
    case highFive, celebrate
    case cuddle, playBow, dance, zoomies
}

enum NudgeAction: Equatable {
    case dismiss
    case snooze(Int)
    case closeTab(String)
    case openWarden
    case openWebsites
    case openAccessories
    case coachBreak
    case openLibrary
    case openSettings
    case openGoals
    case openMyDogs
    case reviewGoalStep(GoalStepReference)
    case postponeGoalCheckIn(GoalStepReference)
    case highFive
    case openCalendarDock
    case joinMeeting(URL)
    case meetingReady
    case captureFollowUp(String)
    case positiveAck
    case openRedirect(NudgeLink, closeHost: String?)
}

struct Nudge: Equatable, Identifiable {
    let id = UUID()
    var mood: Mood
    var action: String          // stage direction, e.g. "lets out a long sigh"
    var badge: String? = nil    // optional context pill, e.g. "5 visits · 18m wasted today"
    var text: String
    var link: NudgeLink? = nil  // clickable hyperlink inside the speech bubble
    var hasTail: Bool = false   // speech bubble tail anchored to the guide dog
    var primary: (label: String, action: NudgeAction)
    var secondary: (label: String, action: NudgeAction)? = nil

    var goalStep: GoalStepReference? {
        if case .reviewGoalStep(let reference) = primary.action { return reference }
        return nil
    }

    var usesSpeechTail: Bool { hasTail || goalStep != nil }

    static func == (a: Nudge, b: Nudge) -> Bool { a.id == b.id }
}

enum PanelPage: Equatable { case warden, weeklyReport, accessories, coach, nextStep }

enum Overlay: Equatable {
    case none
    case bubble(Nudge)
    case menu
    case panel(PanelPage)
}

/// Which companion panel, if any, is open under the dogs.
enum CompanionDock: Equatable {
    case todos
    case calendar
}

/// The review form retains its draft while its closing animation runs.
@MainActor
final class TranscriptDraft: ObservableObject {
    @Published var record: TranscriptRecord

    init(_ record: TranscriptRecord) {
        self.record = record
    }
}

/// Single source of truth for the companion.
@MainActor
final class AppState: ObservableObject {
    @Published var level: Strictness = Prefs.level {
        didSet { Prefs.level = level }
    }
    @Published var coachReminders: Bool = Prefs.coachReminders {
        didSet { Prefs.coachReminders = coachReminders }
    }
    @Published var calendarAssistant: Bool = Prefs.calendarAssistant {
        didSet { Prefs.calendarAssistant = calendarAssistant }
    }
    @Published var overlay: Overlay = .none {
        didSet {
            if overlay != .none { cancelPairPlay() }
            updateMood()
        }
    }
    @Published private(set) var menuDogID: UUID?
    @Published private(set) var mood: Mood = .nap
    @Published private(set) var moodChangedAt = Date()
    @Published private(set) var pairPlay: PairPlayEvent?
    @Published private(set) var focusStreak = 0
    @Published private(set) var bestFocusStreak = Prefs.bestFocusStreak
    @Published private(set) var accessory = Prefs.accessory
    @Published private(set) var report: WeeklyReport?
    @Published private(set) var remindedGoalStep: GoalStepReference?
    @Published var dock: CompanionDock?
    @Published var pendingTodoDraft: String?

    // Archivist draft
    @Published var draftText = ""
    @Published var draftSource = ""
    @Published private(set) var draft: TranscriptDraft?
    @Published private(set) var isOrganizing = false
    @Published private(set) var organizeError: String?
    @Published private(set) var showingTranscriptImport = false
    @Published private(set) var filedTranscriptID: Int64?
    @Published var requestedTranscriptID: Int64?

    let tracker: ActivityTracker
    let library: LibraryStore
    let goalBook: GoalBook
    let appearance: DogAppearance
    let dailyTodos: DailyTodos
    let calendarEvents: CalendarEvents
    let calendarSync: CalendarSync

    var openLibraryWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var openGoalsWindow: (() -> Void)?
    var openMyDogsWindow: (() -> Void)?
    var openWebsitesWindow: (() -> Void)?
    var canShowGoalReminders: () -> Bool = { true }

    private var barkTask: Task<Void, Never>?
    private var bubbleTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var redirectTask: Task<Void, Never>?
    private var pairPlayTask: Task<Void, Never>?
    private var pairPlayScheduler: Task<Void, Never>?
    private var lastPairPlayKind: PairPlayKind?
    private var recentRedirectKeys: [String] = []
    private var reaction: Mood?
    private var temperament = WeeklyTemperament.steady
    private var isLate = FocusCalendar.evening(for: Date()) != nil
    private var isDoomscrolling = false
    private var previousBundle: String?
    private var lastCoachReminder: TimeInterval = 0
    private var streakCheck: (day: String, qualified: Bool)?
    private var runwayNotified: Set<String> = []
    private var wrapNotified: Set<String> = []

    init() {
        tracker = ActivityTracker()
        library = LibraryStore()
        goalBook = GoalBook()
        appearance = DogAppearance()
        dailyTodos = DailyTodos()
        calendarEvents = CalendarEvents()
        calendarSync = CalendarSync()
        tracker.onStreak = { [weak self] event in self?.handleStreak(event) }
        tracker.onDistractionThreshold = { [weak self] event in self?.handleDistractionThreshold(event) ?? false }
        tracker.onSample = { [weak self] sample in self?.handleActivity(sample) }
        tracker.onWalkFinished = { [weak self] in self?.walkFinished() }
        refreshFocusHistory(at: Date())
        if accessory.requiredDays > bestFocusStreak { accessory = .classic }
        updateMood()
        tracker.start()
        scheduleNextPairPlay(initial: true)
    }

    private func updateMood() {
        let new: Mood
        if case .bubble(let nudge) = overlay { new = nudge.mood }
        else if reaction == .celebrate { new = .celebrate }
        else if tracker.walk != nil { new = .walking }
        else if let reaction { new = reaction }
        else if overlay != .none { new = .awake }
        else if isDoomscrolling { new = .coverEyes }
        else if isLate { new = .drowsy }
        else {
            switch temperament {
            case .steady: new = .nap
            case .happy: new = .happy
            case .mopey: new = .mopey
            }
        }
        if new != mood {
            mood = new
            moodChangedAt = Date()
        }
    }

    // MARK: - Interaction

    func toggleDock(_ choice: CompanionDock) {
        dock = dock == choice ? nil : choice
    }

    func dogTapped(_ dogID: UUID? = nil) {
        if mood == .highFive { perform(.highFive); return }
        let id = dogID ?? appearance.guide.id
        switch overlay {
        case .none:
            menuDogID = id
            overlay = .menu
        case .menu where id != (menuDogID ?? appearance.guide.id):
            menuDogID = id
        default:
            overlay = .none
        }
    }

    func perform(_ action: NudgeAction) {
        barkTask?.cancel()
        bubbleTask?.cancel()
        switch action {
        case .dismiss:
            overlay = .none
        case .snooze(let minutes):
            tracker.snooze(minutes: minutes)
            overlay = .none
        case .closeTab(let host):
            tracker.closeDistractingTab(on: host)
            overlay = .none
        case .openWarden:
            overlay = .panel(.warden)
        case .openWebsites:
            overlay = .none
            openWebsitesWindow?()
        case .openAccessories:
            overlay = .panel(.accessories)
        case .coachBreak:
            takeCoachBreak()
        case .openLibrary:
            overlay = .none
            openLibraryWindow?()
        case .openSettings:
            overlay = .none
            openSettingsWindow?()
        case .openGoals:
            overlay = .none
            openGoalsWindow?()
        case .openMyDogs:
            overlay = .none
            openMyDogsWindow?()
        case .reviewGoalStep(let reference):
            remindedGoalStep = reference
            overlay = .panel(.nextStep)
        case .postponeGoalCheckIn(let reference):
            if goalBook.setCheckIn(Date().addingTimeInterval(60 * 60), for: reference) {
                overlay = .none
            } else {
                remindedGoalStep = reference
                overlay = .panel(.nextStep)
            }
        case .highFive:
            overlay = .none
            react(.celebrate, for: 2.5)
        case .openCalendarDock:
            overlay = .none
            dock = .calendar
            react(.wag, for: 2.5)
        case .joinMeeting(let url):
            overlay = .none
            NSWorkspace.shared.open(url)
            react(.celebrate, for: 3)
        case .meetingReady:
            overlay = .none
            react(.wag, for: 3)
        case .captureFollowUp(let title):
            overlay = .none
            pendingTodoDraft = "Follow up: \(title) — "
            dock = .todos
            react(.wag, for: 2.5)
        case .positiveAck:
            overlay = .none
            react(.wag, for: 2.5)
        case .openRedirect(let link, let closeHost):
            if let host = closeHost {
                tracker.closeDistractingTab(on: host)
            }
            switch link.destination {
            case .url(let url):
                overlay = .none
                NSWorkspace.shared.open(url)
                react(.celebrate, for: 3)
            case .libraryTranscript(let id):
                overlay = .none
                requestedTranscriptID = id
                openLibraryWindow?()
                react(.celebrate, for: 3)
            case .goalStep(let reference):
                remindedGoalStep = reference
                overlay = .panel(.nextStep)
                react(.wag, for: 2.5)
            }
        }
    }

    func todoCompleted(allDone: Bool) {
        react(allDone ? .celebrate : .wag, for: allDone ? 3 : 2.2)
    }

    func finishGoalStep(_ reference: GoalStepReference) {
        guard let step = goalBook.setStatus(.done, for: reference) else { return }
        barkTask?.cancel()
        showReminder(mood: .highFive, action: "raises a paw", text: "“\(step.title)” is done.",
                     primary: ("High five", .highFive))
    }

    // MARK: - Daily routine and reactions

    func sessionBecameActive() {
        tracker.setSessionActive(true)
        if markFirstGreeting(at: Date()) { react(.excited, for: 5) }
    }

    func sessionBecameInactive() {
        cancelPairPlay()
        tracker.setSessionActive(false)
        previousBundle = nil
        isDoomscrolling = false
        lastCoachReminder = 0
    }

    func wokeUp() {
        tracker.setSessionActive(true)
        let firstGreeting = markFirstGreeting(at: Date()) || reaction == .excited
        react(.stretch, for: 3, then: firstGreeting ? .excited : nil)
    }

    private func markFirstGreeting(at date: Date) -> Bool {
        let day = ActivityTracker.dayString(date)
        guard Prefs.lastGreetingDay != day else { return false }
        Prefs.lastGreetingDay = day
        return true
    }

    private func react(_ mood: Mood, for seconds: Double, then next: Mood? = nil) {
        cancelPairPlay()
        reactionTask?.cancel()
        reaction = mood
        updateMood()
        reactionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if let next { react(next, for: 5) }
            else {
                reaction = nil
                updateMood()
            }
        }
    }

    private func handleActivity(_ sample: ActivitySample) {
        let evening = FocusCalendar.evening(for: sample.date)
        isLate = evening != nil
        isDoomscrolling = sample.isDistracting && tracker.streakSeconds >= Double(Prefs.sighMinutes) * 60
        if sample.closedDistraction {
            if case .bubble(let nudge) = overlay, case .closeTab = nudge.primary.action { perform(.dismiss) }
            tracker.resetStreak()
            react(.wag, for: 4)
        } else if let bundle = sample.bundleID, bundle != previousBundle,
                  Self.isCodeEditor(bundle), reaction == nil {
            react(.alert, for: 6)
        }
        previousBundle = sample.bundleID

        refreshFocusHistory(at: sample.date)
        updateMood()
        if tracker.deskSeconds < lastCoachReminder { lastCoachReminder = 0 }
        guard sample.isActive, overlay == .none, tracker.walk == nil else { return }

        if calendarAssistant, checkCalendarAssistant(at: sample.date) { return }

        let reminders = Prefs.goalReminders
        let timeAvailable = canShowGoalReminders() && sample.bundleID != Bundle.main.bundleIdentifier
            ? reminders.timeRemaining(at: sample.date) : nil
        if timeAvailable != nil, let next = goalBook.takeDueCheckIn(at: sample.date) {
            showGoalReminder(next, at: sample.date, scheduled: true)
            return
        }
        if deliverWeeklyReportIfDue(at: sample.date) { return }
        if let evening {
            let key = ActivityTracker.dayString(evening)
            if Prefs.lastBedtimeEvening != key {
                Prefs.lastBedtimeEvening = key
                let time = sample.date.formatted(.dateTime.hour().minute())
                showReminder(mood: .drowsy, action: "yawns", text: "It’s \(time). We should sleep.")
                return
            }
        }
        if let timeAvailable, reminders.automatic, Prefs.lastGoalReminderDay != ActivityTracker.dayString(sample.date),
           let next = goalStepToSuggest(fitting: timeAvailable) {
            showGoalReminder(next, at: sample.date, scheduled: false)
            return
        }
        if coachReminders { remindAtDesk() }
    }

    private func checkCalendarAssistant(at date: Date) -> Bool {
        guard calendarSync.isAuthorized else { return false }

        if let upcoming = calendarSync.upcomingRunwayEvent(at: date),
           !runwayNotified.contains(upcoming.id) {
            runwayNotified.insert(upcoming.id)
            let minutes = max(1, Int(ceil(upcoming.startDate.timeIntervalSince(date) / 60)))
            let primary: (String, NudgeAction) = upcoming.meetingURL.map { ("Join meeting", .joinMeeting($0)) }
                ?? ("I’m ready", .meetingReady)
            overlay = .bubble(Nudge(
                mood: .alert,
                action: "perks up for your next event",
                text: "“\(upcoming.title)” starts in \(minutes) min (\(upcoming.timeLabel)). Wrap your thought and join cleanly.",
                primary: primary,
                secondary: ("Dismiss", .dismiss)
            ))
            autoDismiss(after: 45)
            return true
        }

        if let ended = calendarSync.recentlyEndedEvent(at: date),
           !wrapNotified.contains(ended.id) {
            wrapNotified.insert(ended.id)
            overlay = .bubble(Nudge(
                mood: .happy,
                action: "checks in after your meeting",
                text: "“\(ended.title)” just wrapped. Drop any follow-up into Today’s to-do while it’s fresh?",
                primary: ("Add follow-up", .captureFollowUp(ended.title)),
                secondary: ("All clear", .positiveAck)
            ))
            autoDismiss(after: 35)
            return true
        }

        let hour = Calendar.current.component(.hour, from: date)
        let todayKey = ActivityTracker.dayString(date)
        if hour >= 6, hour < 12, Prefs.lastMorningBriefDay != todayKey,
           let shape = calendarSync.dayShape(at: date) {
            Prefs.lastMorningBriefDay = todayKey
            let countLabel = shape.eventCount == 1 ? "1 event today." : "\(shape.eventCount) events today."
            let blockText: String
            if let start = shape.bestBlockStart, let end = shape.bestBlockEnd, shape.bestBlockMinutes >= 45 {
                let startText = start.formatted(date: .omitted, time: .shortened)
                let endText = end.formatted(date: .omitted, time: .shortened)
                blockText = " Your clearest open block is \(startText) – \(endText)."
            } else {
                blockText = " Packed stretch ahead — take quick breathers between them."
            }
            overlay = .bubble(Nudge(
                mood: .happy,
                action: "looks over today’s calendar",
                text: countLabel + blockText,
                primary: ("View calendar", .openCalendarDock),
                secondary: ("Got it", .positiveAck)
            ))
            autoDismiss(after: 30)
            return true
        }

        return false
    }

    private func goalStepToSuggest(fitting seconds: TimeInterval) -> NextGoalStep? {
        func fits(_ candidate: NextGoalStep) -> Bool {
            let minutes = GoalStep.validEstimate(candidate.step.estimatedMinutes) ?? 1
            return Double(minutes) * 60 <= seconds
        }
        if let pinned = goalBook.next {
            return pinned.checkInAt == nil && fits(pinned) ? pinned : nil
        }
        return goalBook.firstPending(matching: fits)
    }

    private func showGoalReminder(_ next: NextGoalStep, at date: Date, scheduled: Bool) {
        Prefs.lastGoalReminderDay = ActivityTracker.dayString(date)
        let text = [next.step.title, next.step.estimateLabel].compactMap { $0 }.joined(separator: "\n")
        let action = scheduled ? "checks in on \(next.goalTitle)" : "suggests a step for \(next.goalTitle)"
        let secondary: (String, NudgeAction) = scheduled ? ("In an hour", .postponeGoalCheckIn(next.reference)) : ("Not today", .dismiss)
        overlay = .bubble(Nudge(mood: .alert, action: action, text: text,
                                primary: ("See step", .reviewGoalStep(next.reference)), secondary: secondary))
        autoDismiss(after: 30)
    }

    private static func isCodeEditor(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        return ["com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
                "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.sublimetext.4", "com.sublimetext.3",
                "com.panic.nova", "com.exafunction.windsurf", "org.vim.macvim", "org.vim.vim"].contains(id)
            || id.hasPrefix("com.jetbrains.")
    }

    // MARK: - Focus history and walks

    func wear(_ accessory: Accessory) {
        guard accessory.requiredDays <= bestFocusStreak else { return }
        self.accessory = accessory
        Prefs.accessory = accessory
    }

    private func refreshFocusHistory(at date: Date) {
        temperament = WeeklyTemperament(days: tracker.recentDays(through: date, count: 7))
        let day = tracker.today.date
        let qualified = tracker.today.focus?.metDailyTarget ?? false
        guard streakCheck?.day != day || streakCheck?.qualified != qualified else { return }
        streakCheck = (day, qualified)
        focusStreak = tracker.focusStreak(through: date)
        guard focusStreak > bestFocusStreak else { return }
        let previousBest = bestFocusStreak
        bestFocusStreak = focusStreak
        Prefs.bestFocusStreak = focusStreak
        if let reward = Accessory.allCases.last(where: { $0.requiredDays > previousBest && $0.requiredDays <= focusStreak }),
           overlay == .none, tracker.walk == nil {
            showReminder(mood: .excited, action: "does a happy dance",
                         text: "\(reward.requiredDays) focus days in a row. You earned the \(reward.title.lowercased()).",
                         primary: ("Accessories", .openAccessories))
        }
    }

    func showWeeklyReport(previous: Bool = false, at date: Date = Date()) {
        report = tracker.weeklyReport(at: date, previous: previous)
        if !previous, FocusCalendar.reportIsDue(at: date), let report {
            Prefs.lastReportWeek = ActivityTracker.dayString(report.start)
        }
        overlay = .panel(.weeklyReport)
    }

    private func deliverWeeklyReportIfDue(at date: Date) -> Bool {
        guard FocusCalendar.reportIsDue(at: date) else { return false }
        let week = ActivityTracker.dayString(FocusCalendar.weekStart(containing: date))
        guard Prefs.lastReportWeek != week else { return false }
        let summary = tracker.weeklyReport(at: date, previous: false)
        guard summary.webSeconds > 0 || (summary.longestStretch ?? 0) > 0 else { return false }
        Prefs.lastReportWeek = week
        report = summary
        overlay = .panel(.weeklyReport)
        return true
    }

    func startFocusWalk() {
        barkTask?.cancel()
        bubbleTask?.cancel()
        redirectTask?.cancel()
        redirectTask = nil
        cancelPairPlay()
        overlay = .none
        tracker.startWalk()
        updateMood()
    }

    func endFocusWalk() {
        tracker.endWalk()
        if overlay == .menu { overlay = .none }
        updateMood()
    }

    private func walkFinished() {
        if overlay == .none {
            showReminder(mood: .wag, action: "wags after the walk", text: "That’s 25 minutes. Good walk!")
        } else {
            react(.wag, for: 4)
        }
    }

    // MARK: - Coach

    func takeCoachBreak() {
        tracker.resetDeskTime()
        lastCoachReminder = 0
        overlay = .none
        react(.stretch, for: 3)
    }

    private func remindAtDesk() {
        guard let due = CoachReminder.latest(at: tracker.deskSeconds), due.time > lastCoachReminder else { return }
        lastCoachReminder = due.time
        switch due.reminder {
        case .posture:
            showReminder(mood: .alert, action: "perks up", text: "How are your shoulders doing? Take a moment to sit comfortably.")
        case .stretch:
            showReminder(mood: .stretch, action: "stretches", text: "Want to take a moment to stretch with me?")
        case .stand:
            showReminder(mood: .alert, action: "gets to his feet", text: "Time to stand up and move around a little.",
                         primary: ("Taking a break", .coachBreak))
        case .water:
            showReminder(mood: .alert, action: "looks up", text: "Water break? Let’s both have a sip.")
        case .walk:
            showReminder(mood: .alert, action: "waits by the door",
                         text: "You’ve been at your Mac for two hours. Want to take a walk?",
                         primary: ("Taking a break", .coachBreak))
        }
    }

    private func showReminder(mood: Mood, action: String, text: String,
                              primary: (String, NudgeAction) = ("Got it", .dismiss)) {
        let later: (String, NudgeAction)? = primary.1 == .dismiss ? nil : ("Later", .dismiss)
        overlay = .bubble(Nudge(mood: mood, action: action, text: text, primary: primary, secondary: later))
        autoDismiss(after: 18)
    }

    // MARK: - Warden

    private func handleStreak(_ e: StreakEvent) {
        // Don't interrupt someone mid-paste.
        if case .panel = overlay { return }
        if case .bubble(let nudge) = overlay,
           nudge.primary.action == .highFive || nudge.goalStep != nil || (nudge.link != nil && e.kind != .bark) { return }
        tracker.countNudge()
        let seconds = Double(e.minutes) * 60
        let miles = Format.miles(forSeconds: seconds)
        let goal = Prefs.focusGoals.lazy.compactMap { goal in
            goal.equivalent(for: seconds).map { "That’s about \($0) for \(goal.name)." }
        }.first
        let comparison = goal ?? "That was a \(miles)-mile run."
        switch e.kind {
        case .sigh:
            overlay = .bubble(Nudge(mood: .sigh, action: "lets out a long sigh",
                                    text: "\(e.minutes) minutes on \(e.host). I’m just going to lie here.",
                                    primary: ("Close tab", .closeTab(e.host)),
                                    secondary: ("Sorry, buddy", .dismiss)))
            autoDismiss(after: 25)
        case .fetch:
            overlay = .bubble(Nudge(mood: .fetch, action: "drops a ball at your feet",
                                    text: "\(e.minutes) minutes on \(e.host). \(comparison) Fetch?",
                                    primary: ("Close tab and go", .closeTab(e.host)),
                                    secondary: ("5 more min (logged)", .snooze(5))))
        case .bark:
            overlay = .bubble(Nudge(mood: .bark, action: "barks",
                                    text: "\(e.minutes) minutes on \(e.host). Woof. I’m closing this tab in 60 seconds.",
                                    primary: ("Close it now", .closeTab(e.host)),
                                    secondary: ("I need it (logged)", .snooze(10))))
            barkTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if case .bubble(let n) = self.overlay, n.mood == .bark { self.perform(.closeTab(e.host)) }
            }
        }
    }

    private func autoDismiss(after seconds: Double) {
        bubbleTask?.cancel()
        let current = overlay
        bubbleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.overlay == current else { return }
            self.overlay = .none
        }
    }

    /// For trying the moods without waiting 20 minutes.
    func demo(_ kind: NudgeKind) {
        let host = tracker.streakHost ?? tracker.currentKey ?? "reddit.com"
        let minutes: Int
        switch kind {
        case .sigh: minutes = Prefs.sighMinutes
        case .fetch: minutes = Prefs.fetchMinutes
        case .bark: minutes = Prefs.barkMinutes
        }
        handleStreak(StreakEvent(kind: kind, host: host, minutes: minutes))
    }

    /// Trigger a spontaneous or requested interplay animation (play, cuddle, 2-leg dance, zoomies).
    func triggerPairPlay(_ requested: PairPlayKind? = nil, force: Bool = false) {
        let hasPair = appearance.visibleDogs.count > 1
        let available = PairPlayKind.allCases.filter { !$0.requiresPair || hasPair }
        guard !available.isEmpty else { return }

        let chosen: PairPlayKind
        if let requested, available.contains(requested) {
            chosen = requested
        } else {
            let pool = available.count > 1 ? available.filter { $0 != lastPairPlayKind } : available
            chosen = pool.randomElement() ?? available[0]
        }

        if force {
            barkTask?.cancel()
            bubbleTask?.cancel()
            reactionTask?.cancel()
            reaction = nil
            overlay = .none
        } else {
            guard canStartRandomPairPlay else { return }
        }

        pairPlayTask?.cancel()
        lastPairPlayKind = chosen
        let event = PairPlayEvent(
            kind: chosen,
            startedAt: Date(),
            leaderIsLeft: Bool.random(),
            seed: Double.random(in: 0...1)
        )
        pairPlay = event
        let duration = chosen.duration
        pairPlayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if self.pairPlay?.id == event.id {
                self.pairPlay = nil
            }
            self.pairPlayTask = nil
        }
    }

    func cancelPairPlay() {
        pairPlayTask?.cancel()
        pairPlayTask = nil
        if pairPlay != nil { pairPlay = nil }
    }

    private var canStartRandomPairPlay: Bool {
        overlay == .none
            && tracker.walk == nil
            && reaction == nil
            && pairPlay == nil
            && !isLate
            && !isDoomscrolling
            && temperament != .mopey
    }

    private func scheduleNextPairPlay(initial: Bool = false) {
        pairPlayScheduler?.cancel()
        let delay = initial ? Double.random(in: 14...28) : Double.random(in: 38...95)
        pairPlayScheduler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.canStartRandomPairPlay {
                self.triggerPairPlay(nil, force: false)
            }
            self.scheduleNextPairPlay(initial: false)
        }
    }

    /// Preview a time-aware goal redirect speech bubble immediately.
    func demoGoalRedirect() {
        let visits = max(Prefs.distractionVisitInterval, tracker.today.distractingVisits(matching: Prefs.isDistracting))
        let seconds = max(TimeInterval(Prefs.distractionMinuteInterval * 60),
                          tracker.today.distractingSeconds(matching: Prefs.isDistracting))
        let event = DistractionThresholdEvent(
            trigger: .visits,
            host: tracker.streakHost,
            totalVisits: visits,
            totalSeconds: seconds,
            date: Date(),
            isDemo: true
        )
        redirectTask?.cancel()
        redirectTask = nil
        overlay = .none
        _ = handleDistractionThreshold(event)
    }

    @discardableResult
    private func handleDistractionThreshold(_ event: DistractionThresholdEvent) -> Bool {
        guard tracker.walk == nil else { return false }
        if !event.isDemo {
            guard overlay == .none, redirectTask == nil else { return false }
        }

        let plans = goalBook.plans
        let pinned = goalBook.next?.reference
        let transcripts = library.records
        let openTodos = dailyTodos.orderedItems.filter { !$0.done }.map(\.title)
        let recent = recentRedirectKeys

        redirectTask = Task { [weak self] in
            let suggestion = await DistractionRedirectEngine.suggest(
                event: event,
                plans: plans,
                pinnedStep: pinned,
                transcripts: transcripts,
                openTodos: openTodos,
                recentKeys: recent
            )
            guard !Task.isCancelled, let self else { return }
            self.redirectTask = nil
            guard self.tracker.walk == nil else { return }
            if !event.isDemo, self.overlay != .none { return }

            self.recentRedirectKeys.removeAll { $0 == suggestion.candidateKey }
            self.recentRedirectKeys.insert(suggestion.candidateKey, at: 0)
            if self.recentRedirectKeys.count > 8 { self.recentRedirectKeys.removeLast() }

            if !event.isDemo { self.tracker.countNudge() }
            let primaryLabel = event.host != nil ? "Close tab & go" : "Go do it"
            let secondary: (String, NudgeAction) = event.isDemo ? ("Later", .dismiss) : ("Snooze 15m", .snooze(15))
            self.overlay = .bubble(Nudge(
                mood: suggestion.mood,
                action: suggestion.stageDirection,
                badge: event.summaryBadge,
                text: suggestion.message,
                link: suggestion.link,
                hasTail: true,
                primary: (primaryLabel, .openRedirect(suggestion.link, closeHost: event.host)),
                secondary: secondary
            ))
            self.autoDismiss(after: 45)
        }
        return true
    }

    // MARK: - Archivist

    func startPaste() {
        if !showingTranscriptImport {
            draft = nil
            organizeError = nil
            showingTranscriptImport = true
            if draftText.isEmpty, let clip = NSPasteboard.general.string(forType: .string), clip.count > 200 {
                draftText = clip
            }
        }
        overlay = .none
        openLibraryWindow?()
    }

    func cancelTranscriptImport() {
        organizeTask?.cancel()
        organizeTask = nil
        isOrganizing = false
        organizeError = nil
        draft = nil
        showingTranscriptImport = false
    }

    func editTranscriptDraft() {
        draft = nil
        organizeError = nil
    }

    func organize() {
        guard showingTranscriptImport, !isOrganizing else { return }
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            organizeError = "Paste some text first."
            return
        }
        let text = draftText
        isOrganizing = true
        organizeError = nil
        let source = draftSource
        let existing = library.categories
        organizeTask = Task { [weak self] in
            do {
                let record = try await Archivist.organize(text: text, sourceHint: source, existing: existing)
                guard !Task.isCancelled, let self else { return }
                draft = TranscriptDraft(record)
                isOrganizing = false
                organizeTask = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                isOrganizing = false
                organizeError = error.localizedDescription
                organizeTask = nil
            }
        }
    }

    func fileDraft(_ draft: TranscriptDraft) {
        guard showingTranscriptImport, self.draft === draft else { return }
        var record = draft.record
        record.title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.title.isEmpty else { organizeError = "Give this transcript a title."; return }
        record.prepareFiling()
        guard let id = library.insert(record) else {
            organizeError = "Doggo couldn’t save the transcript. Try again."
            return
        }
        cancelTranscriptImport()
        draftText = ""
        draftSource = ""
        filedTranscriptID = id
        react(.wag, for: 3)
    }
}

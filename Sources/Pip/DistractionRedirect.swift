import Foundation

struct DistractionThresholdEvent {
    enum Trigger: String {
        case visits
        case minutes
    }

    let trigger: Trigger
    let host: String?
    let totalVisits: Int
    let totalSeconds: TimeInterval
    let date: Date
    let isDemo: Bool

    init(trigger: Trigger, host: String?, totalVisits: Int, totalSeconds: TimeInterval,
         date: Date = Date(), isDemo: Bool = false) {
        self.trigger = trigger
        self.host = host
        self.totalVisits = totalVisits
        self.totalSeconds = totalSeconds
        self.date = date
        self.isDemo = isDemo
    }

    var totalMinutes: Int { Int(totalSeconds / 60) }

    var summaryBadge: String {
        let visitWord = totalVisits == 1 ? "visit" : "visits"
        let timeText = totalSeconds >= 60 ? Format.duration(totalSeconds) : "\(max(1, Int(totalSeconds)))s"
        return "\(totalVisits.formatted()) \(visitWord) · \(timeText) wasted today"
    }
}

struct NudgeLink: Equatable {
    enum Destination: Equatable {
        case url(URL)
        case libraryTranscript(Int64)
        case goalStep(GoalStepReference)
    }

    var label: String
    var destination: Destination

    var iconName: String {
        switch destination {
        case .url: return "arrow.up.right.square"
        case .libraryTranscript: return "book.closed"
        case .goalStep: return "flag"
        }
    }
}

struct GoalRedirectSuggestion {
    let mood: Mood
    let stageDirection: String
    let message: String
    let link: NudgeLink
    let candidateKey: String
}

enum DistractionRedirectEngine {
    struct TimeContext {
        let label: String
        let bucket: String
        let isWorkday: Bool
        let isEvening: Bool
        let isWeekend: Bool
    }

    static func timeContext(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> TimeContext {
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        let isWorkday = !isWeekend && (9..<17).contains(hour)
        let isEvening = (17..<22).contains(hour)

        let partOfDay: String
        switch hour {
        case 5..<12: partOfDay = "morning"
        case 12..<14: partOfDay = "midday"
        case 14..<17: partOfDay = "afternoon"
        case 17..<22: partOfDay = "evening"
        default: partOfDay = "late night"
        }
        let dayKind = isWeekend ? "weekend" : (isWorkday ? "workday" : "weekday")
        let bucket = "\(dayKind) \(partOfDay)"
        let formatted = date.formatted(.dateTime.weekday(.wide).hour().minute())
        return TimeContext(label: "\(formatted) (\(bucket))", bucket: bucket,
                           isWorkday: isWorkday, isEvening: isEvening, isWeekend: isWeekend)
    }

    /// Hybrid selector: starts from saved goals, links, and library study guides, then
    /// optionally lets Claude tailor the message & pick the best time-aware action.
    static func suggest(
        event: DistractionThresholdEvent,
        plans: [GoalPlan],
        pinnedStep: GoalStepReference?,
        transcripts: [TranscriptRecord],
        openTodos: [String],
        recentKeys: [String]
    ) async -> GoalRedirectSuggestion {
        let fallback = localSuggestion(
            event: event,
            plans: plans,
            pinnedStep: pinnedStep,
            transcripts: transcripts,
            recentKeys: recentKeys
        )

        guard Prefs.smartRedirectSuggestions, Prefs.apiKey != nil else {
            return fallback
        }

        if let ai = await claudeSuggestion(
            event: event,
            plans: plans,
            transcripts: transcripts,
            openTodos: openTodos,
            recentKeys: recentKeys,
            fallback: fallback
        ) {
            return ai
        }
        return fallback
    }

    // MARK: - Local deterministic selector

    private struct Candidate {
        let score: Int
        let suggestion: GoalRedirectSuggestion
    }

    static func localSuggestion(
        event: DistractionThresholdEvent,
        plans: [GoalPlan],
        pinnedStep: GoalStepReference?,
        transcripts: [TranscriptRecord],
        recentKeys: [String],
        calendar: Calendar = .autoupdatingCurrent
    ) -> GoalRedirectSuggestion {
        let context = timeContext(for: event.date, calendar: calendar)
        var candidates: [Candidate] = []

        // 1. User's saved goals & steps matching the current time window
        for plan in plans where plan.timeWindow.matches(event.date, calendar: calendar) {
            if let step = plan.steps.first(where: { $0.status == .pending }) {
                let ref = GoalStepReference(goalID: plan.id, stepID: step.id)
                let key = "step:\(step.id.uuidString)"
                let resolvedURL = step.resolvedURL ?? plan.resolvedURL
                let link: NudgeLink
                if let url = resolvedURL {
                    let custom = step.resolvedURL != nil ? step.linkLabel : plan.linkLabel
                    link = NudgeLink(label: GoalLink.displayLabel(for: url, customLabel: custom),
                                     destination: .url(url))
                } else {
                    link = NudgeLink(label: "Open step · \(plan.title)", destination: .goalStep(ref))
                }

                var score = 100 + plan.timeWindow.specificity * 15
                if resolvedURL != nil { score += 18 }
                if pinnedStep == ref { score += 12 }
                if let recentIndex = recentKeys.firstIndex(of: key) {
                    score -= max(25, 60 - recentIndex * 15)
                }

                let estimate = step.estimateLabel.map { " (\($0.lowercased()))" } ?? ""
                let opener = distractionOpener(event: event)
                let message = "\(opener) Swap to \(plan.title): \(step.title)\(estimate)."
                let direction = stageDirection(for: plan.title, isWorkday: context.isWorkday)
                let mood = moodForTopic(plan.title)
                candidates.append(Candidate(
                    score: score,
                    suggestion: GoalRedirectSuggestion(
                        mood: mood,
                        stageDirection: direction,
                        message: message,
                        link: link,
                        candidateKey: key
                    )
                ))
            } else if let url = plan.resolvedURL {
                let key = "goal:\(plan.id.uuidString)"
                let label = GoalLink.displayLabel(for: url, customLabel: plan.linkLabel)
                var score = 90 + plan.timeWindow.specificity * 15
                if let recentIndex = recentKeys.firstIndex(of: key) {
                    score -= max(25, 60 - recentIndex * 15)
                }
                let opener = distractionOpener(event: event)
                let message = "\(opener) Put the next few minutes toward \(plan.title)."
                candidates.append(Candidate(
                    score: score,
                    suggestion: GoalRedirectSuggestion(
                        mood: moodForTopic(plan.title),
                        stageDirection: stageDirection(for: plan.title, isWorkday: context.isWorkday),
                        message: message,
                        link: NudgeLink(label: label, destination: .url(url)),
                        candidateKey: key
                    )
                ))
            }
        }

        // 2. Saved Library transcripts / AI study guides
        for record in transcripts.prefix(8) {
            let key = "library:\(record.id)"
            let openTodo = record.todos.first { !record.doneTodos.contains($0) }
            let takeaway = openTodo ?? record.keyIdeas.first
            let isAIOrStudy = isStudyTopic(record.title + " " + record.category + " " + record.subcategory)

            var score = 72
            if isAIOrStudy { score += 14 }
            if openTodo != nil { score += 8 }
            if !context.isWorkday { score += 6 }
            if let recentIndex = recentKeys.firstIndex(of: key) {
                score -= max(25, 60 - recentIndex * 15)
            }

            let detail: String
            if let takeaway, !takeaway.isEmpty {
                let clipped = takeaway.count > 95 ? String(takeaway.prefix(94)) + "…" : takeaway
                detail = " Try this from “\(record.title)”: \(clipped)"
            } else {
                detail = " Revisit “\(record.title)” in your study library for 5 minutes."
            }
            let opener = distractionOpener(event: event)
            candidates.append(Candidate(
                score: score,
                suggestion: GoalRedirectSuggestion(
                    mood: .alert,
                    stageDirection: "brings over a note from your library",
                    message: opener + detail,
                    link: NudgeLink(label: "Study · \(shortTitle(record.title))",
                                    destination: .libraryTranscript(record.id)),
                    candidateKey: key
                )
            ))
        }

        // 3. Time-aware built-in starters (career, exercise, AI study) so it works out of the box
        for starter in builtInStarters(for: context, event: event) {
            var score = starter.baseScore
            if let recentIndex = recentKeys.firstIndex(of: starter.suggestion.candidateKey) {
                score -= max(25, 60 - recentIndex * 15)
            }
            candidates.append(Candidate(score: score, suggestion: starter.suggestion))
        }

        if let best = candidates.max(by: { $0.score < $1.score }) {
            return best.suggestion
        }

        // Unreachable fallback
        let url = URL(string: "https://www.linkedin.com/jobs/")!
        return GoalRedirectSuggestion(
            mood: .fetch,
            stageDirection: "nudges your hand toward a better tab",
            message: "\(distractionOpener(event: event)) Spend 5 minutes applying to a new role instead.",
            link: NudgeLink(label: "Browse new jobs on LinkedIn", destination: .url(url)),
            candidateKey: "builtin:jobs"
        )
    }

    private struct Starter {
        let baseScore: Int
        let suggestion: GoalRedirectSuggestion
    }

    private static func builtInStarters(for context: TimeContext, event: DistractionThresholdEvent) -> [Starter] {
        let opener = distractionOpener(event: event)
        var list: [Starter] = []

        if context.isWorkday {
            if let url = URL(string: "https://www.linkedin.com/jobs/") {
                list.append(Starter(baseScore: 68, suggestion: GoalRedirectSuggestion(
                    mood: .fetch,
                    stageDirection: "drops a fresh job lead at your feet",
                    message: "\(opener) It’s a workday — use the next 10 minutes to apply to 1 or 2 new roles.",
                    link: NudgeLink(label: "Apply to new jobs on LinkedIn", destination: .url(url)),
                    candidateKey: "builtin:workday-linkedin"
                )))
            }
            if let url = URL(string: "https://www.ycombinator.com/jobs") {
                list.append(Starter(baseScore: 62, suggestion: GoalRedirectSuggestion(
                    mood: .alert,
                    stageDirection: "perks up with a career idea",
                    message: "\(opener) While you’re in work mode, check newly posted roles and send one quick application.",
                    link: NudgeLink(label: "Explore YC Startup Jobs", destination: .url(url)),
                    candidateKey: "builtin:workday-yc"
                )))
            }
        }

        if let url = URL(string: "https://www.youtube.com/results?search_query=10+minute+mobility+workout") {
            let score = context.isWorkday ? 56 : 68
            let text = context.isWorkday
                ? "\(opener) Step away for a quick 10-minute mobility break so you come back sharper."
                : "\(opener) Trade the scroll for a quick workout or stretch session right now."
            list.append(Starter(baseScore: score, suggestion: GoalRedirectSuggestion(
                mood: .stretch,
                stageDirection: "stretches and waits by the door",
                message: text,
                link: NudgeLink(label: "10-min mobility & stretch", destination: .url(url)),
                candidateKey: "builtin:exercise-mobility"
            )))
        }

        if let url = URL(string: "https://www.anthropic.com/research") {
            let score = context.isEvening || context.isWeekend ? 66 : 58
            list.append(Starter(baseScore: score, suggestion: GoalRedirectSuggestion(
                mood: .alert,
                stageDirection: "paws at an AI reading link",
                message: "\(opener) Skim one fresh AI research post and grab one takeaway for your study guide.",
                link: NudgeLink(label: "Read Anthropic Research", destination: .url(url)),
                candidateKey: "builtin:ai-anthropic"
            )))
        }

        if let url = URL(string: "https://lilianweng.github.io/") {
            let score = context.isEvening || context.isWeekend ? 64 : 55
            list.append(Starter(baseScore: score, suggestion: GoalRedirectSuggestion(
                mood: .happy,
                stageDirection: "brings over an AI study guide",
                message: "\(opener) Read one section from an AI study post instead of losing another 10 minutes.",
                link: NudgeLink(label: "Open Lil’Log AI Study Notes", destination: .url(url)),
                candidateKey: "builtin:ai-lillog"
            )))
        }

        return list
    }

    // MARK: - Hybrid Claude generator

    private static let responseSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "stage_direction": [
                "type": "string",
                "description": "Short present-tense dog action, 3 to 7 words, lowercase start, no period. Example: 'nudges your hand with a job link'."
            ],
            "message": [
                "type": "string",
                "description": "1 to 2 concise, warm sentences suggesting one concrete, time-appropriate action tied to the user's goals, exercise, or AI study guide. Mention the wasted visits or minutes lightly without lecturing."
            ],
            "link_label": [
                "type": "string",
                "description": "Short clickable hyperlink label, 2 to 5 words. Example: 'Apply on LinkedIn Jobs' or 'Review AI Study Guide'."
            ],
            "url": [
                "type": "string",
                "description": "An https:// URL to get the action done. Prefer one of the user's saved goal/step URLs if relevant, or a real, reliable URL (like linkedin.com/jobs, anthropic.com/research, arxiv.org/list/cs.AI/recent, or a stretch/workout page). Leave empty string if referencing a library_transcript_id."
            ],
            "library_transcript_id": [
                "type": "integer",
                "description": "If pointing to one of the user's saved library_study_items, return its exact integer id. Otherwise 0."
            ],
            "mood": [
                "type": "string",
                "enum": ["fetch", "alert", "happy", "stretch"]
            ]
        ],
        "required": ["stage_direction", "message", "link_label", "url", "library_transcript_id", "mood"]
    ]

    private static func claudeSuggestion(
        event: DistractionThresholdEvent,
        plans: [GoalPlan],
        transcripts: [TranscriptRecord],
        openTodos: [String],
        recentKeys: [String],
        fallback: GoalRedirectSuggestion
    ) async -> GoalRedirectSuggestion? {
        let context = timeContext(for: event.date)

        let goalPayload: [[String: Any]] = plans.prefix(8).map { plan in
            let pending = plan.steps.filter { $0.status == .pending }.prefix(3).map { step -> [String: Any] in
                [
                    "title": step.title,
                    "minutes": step.estimatedMinutes ?? 0,
                    "url": step.actionURL ?? ""
                ]
            }
            return [
                "title": plan.title,
                "time_window": plan.timeWindow.title,
                "matches_now": plan.timeWindow.matches(event.date),
                "url": plan.actionURL ?? "",
                "link_label": plan.linkLabel ?? "",
                "pending_steps": pending
            ]
        }

        let libraryPayload: [[String: Any]] = transcripts.prefix(6).map { record in
            let openTodo = record.todos.first { !record.doneTodos.contains($0) } ?? ""
            return [
                "id": record.id,
                "title": record.title,
                "category": record.path,
                "key_idea": record.keyIdeas.first ?? "",
                "open_todo": openTodo
            ]
        }

        let payload: [String: Any] = [
            "current_time": context.label,
            "is_workday": context.isWorkday,
            "distraction": [
                "current_site": event.host ?? "a distracting site",
                "total_visits_today": event.totalVisits,
                "total_minutes_today": event.totalMinutes,
                "triggered_by": event.trigger.rawValue
            ],
            "goals": goalPayload,
            "library_study_items": libraryPayload,
            "today_open_todos": Array(openTodos.prefix(6)),
            "recently_suggested": Array(recentKeys.prefix(4))
        ]

        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let userJSON = String(data: encoded, encoding: .utf8) else {
            return nil
        }

        let system = """
        You are the voice of a friendly desktop dog companion nudging the user off distracting websites.
        The user just crossed a daily wasted-site visit or time threshold.
        Pick ONE concrete, immediately actionable, time-aware suggestion:
        - Strongly prefer the user's own goals whose time_window matches right now (and use their saved goal/step URL when present).
        - During a workday, career actions (like applying to new jobs), focused goal steps, or short 5-10 min desk/exercise resets fit best.
        - Outside core work hours (or when goals don't cover right now), exercise/movement, AI articles, or reviewing a saved item from library_study_items fit great.
        - Never invent broken or fake deep links; use either the user's saved URL, an exact library_transcript_id from library_study_items, or a clean top-level/search URL on a major site.
        - Keep the message under 190 characters, friendly, direct, and never preachy.
        """

        // Race Claude against an 8-second timeout so the bubble stays responsive.
        let result: [String: Any]? = await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask {
                try? await ClaudeClient.jsonObject(system: system, user: userJSON,
                                                   schema: responseSchema, maxTokens: 512)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let reply = result,
              let rawMessage = (reply["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawMessage.isEmpty else {
            return nil
        }

        let rawDirection = (reply["stage_direction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let direction = (rawDirection?.isEmpty == false ? rawDirection! : fallback.stageDirection)
        let rawLabel = (reply["link_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let mood: Mood
        switch reply["mood"] as? String {
        case "alert": mood = .alert
        case "happy": mood = .happy
        case "stretch": mood = .stretch
        default: mood = .fetch
        }

        let transcriptID = (reply["library_transcript_id"] as? Int64)
            ?? (reply["library_transcript_id"] as? Int).map(Int64.init)
            ?? 0

        let link: NudgeLink
        let key: String
        if transcriptID > 0, let matched = transcripts.first(where: { $0.id == transcriptID }) {
            let label = (rawLabel?.isEmpty == false ? rawLabel! : "Study · \(shortTitle(matched.title))")
            link = NudgeLink(label: label, destination: .libraryTranscript(matched.id))
            key = "library:\(matched.id)"
        } else if let url = GoalLink.normalizeURL(reply["url"] as? String) {
            let label = GoalLink.displayLabel(for: url, customLabel: rawLabel)
            link = NudgeLink(label: label, destination: .url(url))
            key = "url:\(url.absoluteString.lowercased())"
        } else {
            link = fallback.link
            key = fallback.candidateKey
        }

        return GoalRedirectSuggestion(
            mood: mood,
            stageDirection: direction,
            message: rawMessage,
            link: link,
            candidateKey: key
        )
    }

    // MARK: - Helpers

    private static func distractionOpener(event: DistractionThresholdEvent) -> String {
        let visits = event.totalVisits
        let mins = event.totalMinutes
        switch event.trigger {
        case .visits:
            if mins >= 2 {
                return "Visit #\(visits) to distracting sites (\(mins)m today)."
            }
            return "That’s \(visits) visits to distracting sites today."
        case .minutes:
            return "\(mins) minutes across \(visits) distracting \(visits == 1 ? "visit" : "visits") today."
        }
    }

    private static func stageDirection(for topic: String, isWorkday: Bool) -> String {
        let lower = topic.lowercased()
        if lower.contains("run") || lower.contains("workout") || lower.contains("exercise") || lower.contains("gym") || lower.contains("walk") {
            return "brings over your running shoes"
        }
        if lower.contains("job") || lower.contains("career") || lower.contains("apply") || lower.contains("interview") {
            return "nudges your elbow with a job link"
        }
        if isStudyTopic(lower) {
            return "drops a study note at your feet"
        }
        return isWorkday ? "nudges your hand toward a better tab" : "drops a ball by your goal list"
    }

    private static func moodForTopic(_ topic: String) -> Mood {
        let lower = topic.lowercased()
        if lower.contains("run") || lower.contains("workout") || lower.contains("exercise") || lower.contains("stretch") {
            return .stretch
        }
        if isStudyTopic(lower) { return .alert }
        return .fetch
    }

    private static func isStudyTopic(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["ai", "llm", "machine learning", "study", "paper", "article", "learn", "course", "research", "ml", "agent"]
        return keywords.contains { lower.contains($0) }
    }

    private static func shortTitle(_ title: String) -> String {
        title.count > 28 ? String(title.prefix(27)) + "…" : title
    }
}

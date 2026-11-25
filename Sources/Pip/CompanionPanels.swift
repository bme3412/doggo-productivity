import SwiftUI

struct FocusWalkProgress: View {
    @ObservedObject var tracker: ActivityTracker

    var body: some View {
        if let walk = tracker.walk {
            TimelineView(.periodic(from: walk.start, by: 1)) { timeline in
                let remaining = walk.remaining(at: timeline.date)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Walk")
                        Spacer(minLength: 0)
                        Text(Format.countdown(remaining)).monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    ProgressView(value: FocusWalk.duration - remaining, total: FocusWalk.duration)
                        .progressViewStyle(.linear)
                        .tint(Theme.trail)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 95)
                .background(.white, in: RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Focus walk")
                .accessibilityValue("\(Format.countdown(remaining)) remaining")
            }
        }
    }
}

struct WeeklyReportPanel: View {
    var report: WeeklyReport
    var changeWeek: () -> Void
    var openWebsites: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                let date = Date.FormatStyle().month(.abbreviated).day()
                Text("\(report.start.formatted(date)) – \(report.through.formatted(date))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer()
                PillButton(title: report.isPrevious ? "This week" : "Last week", action: changeWeek)
                    .background(Theme.trail.opacity(0.09), in: Capsule())
            }
            FocusSummaryCard(title: "Longest focus stretch",
                             value: report.longestStretch.map { Format.duration($0) } ?? "—", metrics: [
                .init(label: "Online", value: Format.duration(report.webSeconds)),
                .init(label: "Sites", value: report.topSites.count.formatted())
            ], detail: report.longestStretch == nil ? "No focus data for this period" : nil, comparison: trend)

            TopWebsiteRows(sites: report.topSites, openWebsites: openWebsites)

            if report.distractingSeconds >= 60 {
                DistractionSummary(seconds: report.distractingSeconds)
            }
        }
    }

    private var trend: String {
        let change = report.webSeconds - report.priorWebSeconds
        let comparison = report.isPrevious ? "the week before" : "the same days last week"
        if report.priorWebSeconds == 0 { return "No browsing logged in \(comparison)." }
        if abs(change) < 60 { return "About the same time online as \(comparison)." }
        return "\(Format.duration(abs(change))) \(change < 0 ? "less" : "more") online than \(comparison)."
    }
}

struct GoalComparisons: View {
    var seconds: TimeInterval

    var body: some View {
        ForEach(Prefs.focusGoals) { goal in
            if let amount = goal.equivalent(for: seconds) {
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.name)
                    Spacer(minLength: 8)
                    Text("About \(amount)").multilineTextAlignment(.trailing)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct AccessoriesPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(state.focusStreak) \(state.focusStreak == 1 ? "day" : "days") in a row")
                .font(.system(size: 18, weight: .semibold))
            Text("A day counts after 25 minutes of tracked focus.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(Accessory.allCases) { accessory in
                let unlocked = accessory.requiredDays <= state.bestFocusStreak
                Button { state.wear(accessory) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: accessory == .brassTag ? "tag.fill" : "triangle.fill")
                            .foregroundStyle(accessory == .trailBandana ? Theme.trail : Theme.amber)
                            .frame(width: 19)
                        Text(accessory.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if state.accessory == accessory {
                            Label("Wearing", systemImage: "checkmark").font(.system(size: 11))
                        } else if !unlocked {
                            Label("\(accessory.requiredDays) days", systemImage: "lock").font(.system(size: 11))
                        } else {
                            Text("Wear").font(.system(size: 11))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!unlocked)
            }
        }
    }
}

struct CoachPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: ActivityTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Format.duration(tracker.deskSeconds)) at your Mac")
                .font(.system(size: 20, weight: .semibold))
            Text(state.coachReminders
                 ? "Next stand break in \(Format.countdown(CoachReminder.untilNextStand(at: tracker.deskSeconds)))."
                 : "Desk reminders are paused.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .monospacedDigit()
            Toggle("Posture, stretch, and water reminders", isOn: $state.coachReminders)
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .medium))
            Text("Doggo checks in about posture, stretching, and water. After two hours at your Mac, he’ll suggest a walk.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "I took a break", primary: true) { state.takeCoachBreak() }
        }
    }
}

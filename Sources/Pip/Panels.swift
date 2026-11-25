import SwiftUI

// MARK: - Warden

struct WardenPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: ActivityTracker

    var body: some View {
        let stats = tracker.today
        let distracted = stats.focus?.distracted ?? stats.distractingSeconds(matching: Prefs.isDistracting)
        let distractingVisits = stats.distractingVisits(matching: Prefs.isDistracting)

        VStack(alignment: .leading, spacing: 10) {
            dailySummary(stats)

            TopWebsiteRows(sites: stats.topSites,
                           emptyMessage: "No websites logged yet today. Check System Settings › Privacy & Security › Automation if Doggo can’t read your browser.") {
                state.perform(.openWebsites)
            }

            if distracted >= 60 || distractingVisits > 0 {
                DistractionSummary(seconds: distracted, visits: distractingVisits,
                                   streakHost: tracker.streakHost, streakSeconds: tracker.streakSeconds)
            }
            reminderControl
        }
    }

    private func dailySummary(_ stats: DayStats) -> some View {
        let focused = stats.focus?.focused ?? 0
        let progress = min(focused / FocusStats.dailyTarget, 1)
        let minutesToGoal = Int(ceil(max(0, FocusStats.dailyTarget - focused) / 60))
        let streakText = switch minutesToGoal {
        case 0: "Daily streak goal met"
        default: "\(minutesToGoal) min to earn a streak day"
        }
        return FocusSummaryCard(title: "Focus time", value: Format.duration(focused), metrics: [
            .init(label: "Online", value: Format.duration(stats.webSeconds)),
            .init(label: "Sites", value: stats.siteCount.formatted()),
            .init(label: "Snoozes", value: stats.snoozes.formatted())
        ], detail: streakText, streakProgress: progress)
    }

    private var reminderControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Warden reminders").font(.system(size: 12, weight: .semibold))
            Picker("Warden reminders", selection: $state.level) {
                ForEach(Strictness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(state.level.explanation)
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Activity report cards

struct FocusSummaryCard: View {
    struct Metric {
        let label: String
        let value: String
    }

    let title: String
    let value: String
    let metrics: [Metric]
    var detail: String?
    var streakProgress: Double?
    var comparison: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.reportHighlight)
                    Text(value)
                        .font(.system(size: 33, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.reportHighlight)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                ZStack {
                    if let streakProgress {
                        Circle().strokeBorder(.white.opacity(0.2), lineWidth: 4)
                        Circle().trim(from: 0, to: streakProgress)
                            .stroke(Theme.reportHighlight, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(2)
                    } else {
                        Circle().fill(.white.opacity(0.12))
                    }
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.reportHighlight)
                }
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            }
            .frame(minHeight: 74)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .foregroundStyle(Color.white)
            .background(Theme.reportGradient)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 0) {
                    ForEach(metrics.indices, id: \.self) { index in
                        if index > 0 { Divider().frame(height: 23) }
                        metric(metrics[index])
                    }
                }
                if let comparison {
                    Divider().padding(.horizontal, 15)
                    Text(comparison)
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 15)
                }
            }
            .padding(.vertical, 7)
            .background(Color(hex: 0xF1EBDD))
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func metric(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(metric.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .accessibilityElement(children: .combine)
    }
}

struct DistractionSummary: View {
    let seconds: TimeInterval
    var visits: Int? = nil
    var streakHost: String?
    var streakSeconds: TimeInterval = 0

    private var headline: String {
        let time = seconds >= 60 ? Format.duration(seconds) : "\(Int(seconds))s"
        if let visits, visits > 0 {
            let word = visits == 1 ? "visit" : "visits"
            return "\(visits.formatted()) \(word) · \(time) on distracting sites"
        }
        return "\(time) on distracting sites"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0xF0DDC5), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 12, weight: .semibold))
                    if seconds >= 60 {
                        Text("About a \(Format.miles(forSeconds: seconds))-mile run")
                            .font(.system(size: 11))
                    }
                }
            }
            .foregroundStyle(Theme.amberText)
            if let host = streakHost, streakSeconds >= 60 {
                Text("Current streak · \(Format.duration(streakSeconds)) on \(host)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .lineLimit(2).help(host)
            }
            GoalComparisons(seconds: seconds)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF9EFDF), in: RoundedRectangle(cornerRadius: 11))
    }
}

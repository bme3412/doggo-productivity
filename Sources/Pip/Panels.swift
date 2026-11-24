import SwiftUI

// MARK: - Warden

struct WardenPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: ActivityTracker

    var body: some View {
        let stats = tracker.today
        let distracted = stats.focus?.distracted ?? stats.sites.filter { Prefs.isDistracting($0.key) }.values.reduce(0, +)

        VStack(alignment: .leading, spacing: 10) {
            dailySummary(stats)

            TopWebsiteRows(sites: stats.topSites,
                           emptyMessage: "No websites logged yet today. Check System Settings › Privacy & Security › Automation if Doggo can’t read your browser.") {
                state.perform(.openWebsites)
            }

            if distracted >= 60 { distractionSummary(distracted) }
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
        let highlight = Color(hex: 0xD3E6B9)

        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Focus time")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(highlight)
                    Text(Format.duration(focused))
                        .font(.system(size: 33, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(streakText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(highlight)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.2), lineWidth: 4)
                    Circle().trim(from: 0, to: progress)
                        .stroke(highlight, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(highlight)
                }
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .foregroundStyle(Color.white)
            .background(LinearGradient(colors: [Color(hex: 0x305A49), Color(hex: 0x1C3C32)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))

            HStack(spacing: 0) {
                metric(Format.duration(stats.webSeconds), "Online")
                Divider().frame(height: 23)
                metric(stats.siteCount.formatted(), "Sites")
                Divider().frame(height: 23)
                metric(stats.snoozes.formatted(), "Snoozes")
            }
            .padding(.vertical, 7)
            .background(Color(hex: 0xF1EBDD))
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .accessibilityElement(children: .combine)
    }

    private func distractionSummary(_ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0xF0DDC5), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Format.duration(seconds)) on distracting sites")
                        .font(.system(size: 12, weight: .semibold))
                    Text("About a \(Format.miles(forSeconds: seconds))-mile run")
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(Theme.amberText)
            if let host = tracker.streakHost, tracker.streakSeconds >= 60 {
                Text("Current streak · \(Format.duration(tracker.streakSeconds)) on \(host)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .lineLimit(2).help(host)
            }
            GoalComparisons(seconds: seconds)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF9EFDF), in: RoundedRectangle(cornerRadius: 11))
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

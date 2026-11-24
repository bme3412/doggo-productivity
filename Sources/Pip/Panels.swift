import SwiftUI
import AppKit

// MARK: - Warden

struct WardenPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var tracker: ActivityTracker

    var body: some View {
        let stats = tracker.today
        let distracted = stats.focus?.distracted ?? stats.sites.filter { Prefs.isDistracting($0.key) }.values.reduce(0, +)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 17) {
                stat(Format.duration(stats.webSeconds), "online today")
                stat("\(stats.siteCount)", "sites")
                stat(Format.duration(stats.focus?.focused ?? 0), "focused")
                stat("\(stats.snoozes)", "snoozes")
            }

            TopWebsiteRows(sites: stats.topSites) { state.perform(.openWebsites) }
            if stats.sites.isEmpty {
                Text("No browsing logged yet today. If this stays empty, allow Doggo to control your browser in System Settings › Privacy & Security › Automation.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let host = tracker.streakHost, tracker.streakSeconds >= 60 {
                Text("Current streak: \(Format.duration(tracker.streakSeconds)) on \(host)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if distracted >= 60 {
                Text("\(Format.duration(distracted)) on distracting sites could have been \(Format.miles(forSeconds: distracted)) miles.")
                    .font(.system(size: 12)).foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                GoalComparisons(seconds: distracted)
            }

            Divider()
            Text("How pushy should I be?").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Picker("", selection: $state.level) {
                ForEach(Strictness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(state.level.explanation + "  (Sigh \(Prefs.sighMinutes)m · Fetch \(Prefs.fetchMinutes)m · Bark \(Prefs.barkMinutes)m)")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }
}

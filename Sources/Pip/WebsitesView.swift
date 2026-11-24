import SwiftUI

private enum WebsiteRange: String, CaseIterable {
    case today = "Today"
    case week = "7 days"
    case month = "30 days"
    case all = "All time"
}

private enum WebsiteSort: String, CaseIterable {
    case time = "Time"
    case visits = "Visits"
}

struct WebsitesView: View {
    @ObservedObject var tracker: ActivityTracker
    @State private var range: WebsiteRange = .today
    @State private var order: WebsiteSort = .time
    @State private var host: String?
    @State private var search = ""

    private var days: [DayStats] {
        switch range {
        case .today: return [tracker.today]
        case .week: return tracker.recentDays(through: Date(), count: 7)
        case .month: return tracker.recentDays(through: Date(), count: 30)
        case .all: return tracker.allDays()
        }
    }

    var body: some View {
        let days = days
        let sites = matchingSites(days)
        VStack(spacing: 0) {
            controls
            Divider()
            if sites.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No websites in this range" : "No matching websites",
                                       systemImage: "safari")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    table(sites)
                        .frame(minWidth: 370, maxHeight: .infinity)
                    if let selected = sites.first(where: { $0.host == host }) ?? sites.first {
                        WebsiteDetail(site: selected, days: days)
                            .frame(minWidth: 305, idealWidth: 340, maxWidth: 445, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("A visit starts when Doggo sees you enter or return to a website.")
                Spacer()
                VisitCoverageLabel(sites: sites)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: sites.map(\.host), initial: true) { _, available in
            if host == nil || !available.contains(host ?? "") { host = available.first }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Period", selection: $range) {
                ForEach(WebsiteRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 295)
            .accessibilityLabel("Period")

            Spacer()
            TextField("Find a website", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 174)

            Picker("Sort by", selection: $order) {
                ForEach(WebsiteSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
        .padding(14)
    }

    private func matchingSites(_ days: [DayStats]) -> [SiteTime] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sites = SiteTime.totals(for: days).filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) }
        guard order == .visits else { return sites }
        return sites.sorted { first, second in
            let lhs = first.visits ?? -1
            let rhs = second.visits ?? -1
            if lhs != rhs { return lhs > rhs }
            return first.seconds == second.seconds ? first.host < second.host : first.seconds > second.seconds
        }
    }

    private func table(_ sites: [SiteTime]) -> some View {
        Table(sites, selection: $host) {
            TableColumn("Website") { site in
                Text(site.host).lineLimit(1).help(site.host)
            }
            TableColumn("Visits") { site in
                VisitCountText(site: site).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 51, ideal: 65, max: 95)
            TableColumn("Time") { site in
                Text(Format.websiteDuration(site.seconds)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 65, ideal: 83, max: 110)
        }
    }
}

private struct WebsiteDetail: View {
    var site: SiteTime
    var days: [DayStats]

    private struct DailyRow: Identifiable {
        let date: String
        let site: SiteTime
        var id: String { date }
    }

    private static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var history: [DailyRow] {
        days.compactMap { day in
            guard let seconds = day.sites[site.host], seconds > 0 else { return nil }
            let counted = day.siteVisits?[site.host]
            return DailyRow(date: day.date, site: SiteTime(host: site.host, seconds: seconds,
                                                            visits: counted?.count,
                                                            countedSeconds: counted?.seconds ?? 0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                Text(site.host).font(.system(size: 21, weight: .semibold))
                    .textSelection(.enabled).help(site.host)
                    .lineLimit(2)
                HStack(alignment: .top, spacing: 18) {
                    metric("Visits") { VisitCountText(site: site) }
                    metric("Time") { Text(Format.websiteDuration(site.seconds)) }
                    metric("Active days") { Text(site.activeDays.formatted()) }
                }
            }
            .padding(17)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Daily breakdown").font(.headline)
                line(day: Text("Day"), visits: Text("Visits"), time: Text("Time"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 4)

            List(history) { row in
                line(day: Text(dateLabel(row.date)), visits: VisitCountText(site: row.site),
                     time: Text(Format.websiteDuration(row.site.seconds)).monospacedDigit())
                .font(.callout)
                .padding(.vertical, 3)
                .listRowInsets(EdgeInsets(top: 0, leading: 17, bottom: 0, trailing: 17))
            }
            .listStyle(.plain)
        }
    }

    private func metric<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            value().font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func line<V: View, T: View>(day: Text, visits: V, time: T) -> some View {
        HStack {
            day
            Spacer(minLength: 4)
            visits.frame(width: 50, alignment: .trailing)
            time.frame(width: 67, alignment: .trailing)
        }
    }

    private func dateLabel(_ key: String) -> String {
        Self.dateParser.date(from: key)?.formatted(.dateTime.month(.abbreviated).day().year()) ?? key
    }
}

struct VisitCountText: View {
    let site: SiteTime

    var body: some View {
        Text(site.visitCountLabel)
            .monospacedDigit()
            .accessibilityLabel(site.visitAccessibilityLabel)
            .help(site.visitAccessibilityLabel)
    }
}

struct VisitCoverageLabel: View {
    let sites: [SiteTime]

    var body: some View {
        let earlier = sites.contains { $0.visits == nil }
        let partial = sites.contains(where: \.isPartial)
        if earlier || partial {
            HStack(spacing: 10) {
                if earlier { Text("— Count unavailable") }
                if partial { Text("+ Partial count") }
            }
        }
    }
}

struct TopWebsiteRows: View {
    let sites: [SiteTime]
    let openWebsites: () -> Void

    var body: some View {
        let top = Array(sites.prefix(5))
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Top websites").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("All websites", action: openWebsites)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            if let first = top.first {
                HStack(spacing: 8) {
                    Spacer()
                    Text("Visits").frame(width: 46, alignment: .trailing)
                    Text("Time").frame(width: 58, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                ForEach(top) { site in
                    HStack(spacing: 8) {
                        Text(site.host).lineLimit(1).frame(width: 115, alignment: .leading).help(site.host)
                        ProgressView(value: site.seconds, total: max(1, first.seconds))
                            .progressViewStyle(.linear)
                            .tint(Theme.sage)
                            .accessibilityHidden(true)
                        VisitCountText(site: site).frame(width: 46, alignment: .trailing)
                        Text(Format.websiteDuration(site.seconds)).monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                VisitCoverageLabel(sites: top).font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }
}

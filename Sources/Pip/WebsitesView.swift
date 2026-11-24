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
        VStack(spacing: 12) {
            controls
            if sites.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No websites in this range" : "No matching websites",
                                       systemImage: "safari")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .doggoWindowCard()
            } else {
                HSplitView {
                    websiteList(sites)
                        .padding(.trailing, 6)
                        .frame(minWidth: 370, maxHeight: .infinity)
                    if let selected = sites.first(where: { $0.host == host }) ?? sites.first {
                        WebsiteDetail(site: selected, days: days)
                            .padding(.leading, 6)
                            .frame(minWidth: 305, idealWidth: 340, maxWidth: 445, maxHeight: .infinity)
                    }
                }
            }
            HStack(spacing: 12) {
                Text("A visit starts when Doggo sees you enter or return to a website.")
                Spacer()
                VisitCoverageLabel(sites: sites)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(LibraryColors.paper)
        .tint(LibraryColors.accent)
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

    private func websiteList(_ sites: [SiteTime]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(sites.count.formatted()) \(sites.count == 1 ? "website" : "websites")")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            table(sites)
        }
        .doggoWindowCard()
    }

    private func table(_ sites: [SiteTime]) -> some View {
        let mostTime = sites.map(\.seconds).max() ?? 1
        return Table(sites, selection: $host) {
            TableColumn("Website") { site in
                VStack(alignment: .leading, spacing: 4) {
                    Text(site.host).fontWeight(.medium).lineLimit(1).help(site.host)
                    WebsiteTimeBar(seconds: site.seconds, maximum: mostTime, color: LibraryColors.accent)
                }
                .padding(.vertical, 4)
            }
            TableColumn("Visits") { site in
                VisitCountText(site: site).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 51, ideal: 65, max: 95)
            TableColumn("Time") { site in
                Text(Format.websiteDuration(site.seconds)).fontWeight(.medium).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 65, ideal: 83, max: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: 12) {
            summary
            dailyBreakdown
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            DoggoWindowHeader {
                Text(site.host)
                    .textSelection(.enabled).help(site.host)
                    .lineLimit(2)
            }

            HStack(spacing: 0) {
                metric("Visits") { VisitCountText(site: site) }
                Divider().frame(height: 23)
                metric("Time") { Text(Format.websiteDuration(site.seconds)) }
                Divider().frame(height: 23)
                metric("Active days") { Text(site.activeDays.formatted()) }
            }
            .padding(.vertical, 9)
            .background(LibraryColors.shelf)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var dailyBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Daily breakdown").font(.system(size: 14, weight: .semibold))
                line(day: Text("Day"), visits: Text("Visits"), time: Text("Time"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 4)

            List(history) { row in
                line(day: Text(dateLabel(row.date)), visits: VisitCountText(site: row.site),
                     time: Text(Format.websiteDuration(row.site.seconds)).monospacedDigit())
                .font(.callout)
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .doggoWindowCard()
    }

    private func metric<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            value()
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
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

private struct WebsiteTimeBar: View {
    let seconds: TimeInterval
    let maximum: TimeInterval
    var color = Theme.trail

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(color.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * (seconds / max(1, maximum)))
                }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
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
    var emptyMessage = "No websites logged for this period."
    let openWebsites: () -> Void

    var body: some View {
        let top = Array(sites.prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top websites").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openWebsites) {
                    HStack(spacing: 5) {
                        Text("All websites")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.trail)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 25)
                    .background(Theme.trail.opacity(0.09), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open website history")
            }
            .padding(.bottom, 5)

            if let first = top.first {
                HStack(spacing: 12) {
                    Spacer()
                    Text("Visits").frame(width: 44, alignment: .trailing)
                    Text("Time").frame(width: 49, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.muted)
                ForEach(top) { site in
                    row(site, timeScale: first.seconds)
                }
                VisitCoverageLabel(sites: top)
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .padding(.top, 4)
            } else {
                Text(emptyMessage)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white)
                .strokeBorder(Theme.line)
        }
    }

    private func row(_ site: SiteTime, timeScale: TimeInterval) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(site.host).fontWeight(.medium).lineLimit(1).help(site.host)
                WebsiteTimeBar(seconds: site.seconds, maximum: timeScale)
            }
            VisitCountText(site: site)
                .foregroundStyle(Theme.muted)
                .frame(width: 44, alignment: .trailing)
            Text(Format.websiteDuration(site.seconds)).fontWeight(.medium).monospacedDigit()
                .frame(width: 49, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 4)
    }
}

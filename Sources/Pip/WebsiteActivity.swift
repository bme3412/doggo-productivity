import Foundation

struct SiteVisits: Codable {
    var count = 0
    var seconds: TimeInterval = 0
}

struct SiteTime: Identifiable {
    var host: String
    var seconds: TimeInterval = 0
    var visits: Int?
    var countedSeconds: TimeInterval = 0
    var activeDays = 0

    var id: String { host }
    var isPartial: Bool { visits != nil && countedSeconds < seconds }

    var visitCountLabel: String {
        guard let visits else { return "—" }
        return visits.formatted() + (isPartial ? "+" : "")
    }

    var visitAccessibilityLabel: String {
        guard let visits else { return "Visit count unavailable" }
        let unit = visits == 1 ? "visit" : "visits"
        return (isPartial ? "At least " : "") + "\(visits.formatted()) \(unit)"
    }

    static func totals(for days: [DayStats]) -> [Self] {
        var totals: [String: Self] = [:]
        for day in days {
            for (host, seconds) in day.sites where seconds > 0 {
                var site = totals[host, default: Self(host: host)]
                site.seconds += seconds
                site.activeDays += 1
                if let counted = day.siteVisits?[host] {
                    site.visits = (site.visits ?? 0) + counted.count
                    site.countedSeconds += counted.seconds
                }
                totals[host] = site
            }
        }
        return totals.values.sorted { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.host < rhs.host : lhs.seconds > rhs.seconds
        }
    }
}

/// One foreground stretch on the same host is a visit.
struct SiteVisitSession {
    private var host: String?
    private var lastSeen: Date?

    mutating func observe(_ site: String, at date: Date, maximumGap: TimeInterval) -> Bool {
        let gap = lastSeen.map { date.timeIntervalSince($0) }
        let continuing = host == site && gap.map { $0 >= 0 && $0 <= maximumGap } == true
        host = site
        lastSeen = date
        return !continuing
    }

    mutating func leave() {
        host = nil
        lastSeen = nil
    }
}

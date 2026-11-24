import Foundation

struct GoalReminderSchedule: Codable, Equatable {
    struct Window: Codable, Equatable {
        var start: Int
        var end: Int
    }

    var automatic = true
    var weekdays = Window(start: 17 * 60, end: 21 * 60)
    var weekends = Window(start: 9 * 60, end: 21 * 60)

    func timeRemaining(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> TimeInterval? {
        let today = calendar.startOfDay(for: date)
        let days = [today, calendar.date(byAdding: .day, value: -1, to: today)].compactMap { $0 }
        return days.compactMap { day in
            endOfWindow(startingOn: day, containing: date, calendar: calendar)
        }.max()?.timeIntervalSince(date)
    }

    private func endOfWindow(startingOn day: Date, containing date: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: day)
        let window = weekday == 1 || weekday == 7 ? weekends : weekdays
        guard window.start != window.end,
              let start = Self.date(at: window.start, on: day, calendar: calendar), start <= date,
              let endDay = calendar.date(byAdding: .day, value: window.end < window.start ? 1 : 0, to: day),
              let end = Self.date(at: window.end, on: endDay, calendar: calendar), date < end else { return nil }
        return end
    }

    static func date(at minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        guard (0..<1440).contains(minutes) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    static func minutes(at date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

import Foundation

enum DateParser {
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let weekdaysZh = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    static func startOfDay(_ ms: TimeInterval) -> TimeInterval {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000
    }

    static func windowStart(_ now: TimeInterval, months: Int) -> TimeInterval {
        let date = Date(timeIntervalSince1970: now / 1000)
        let shifted = Calendar.current.date(byAdding: .month, value: -months, to: date) ?? date
        return Calendar.current.startOfDay(for: shifted).timeIntervalSince1970 * 1000
    }

    static func parse(_ label: String, now: TimeInterval = Date().timeIntervalSince1970 * 1000, dateOrder: String = "mdy") -> TimeInterval? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count > 40 { return nil }
        if text.lowercased() == "today" || text == "今天" || text == "今日" { return startOfDay(now) }
        if text.lowercased() == "yesterday" || text == "昨天" || text == "昨日" { return startOfDay(now) - 86_400_000 }
        if let weekday = weekdayIndex(text) {
            let today = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: now / 1000)) - 1
            let delta = (today - weekday + 7) % 7
            return startOfDay(now) - Double(delta) * 86_400_000
        }
        if let chinese = firstMatch(text, #"^(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日$"#) {
            let month = Int(chinese[2])! - 1
            let day = Int(chinese[3])!
            if !chinese[1].isEmpty { return dayStart(Int(chinese[1])!, month, day) }
            return yearsBack(month, day, now)
        }
        if let iso = firstMatch(text, #"^(\d{4})-(\d{2})-(\d{2})$"#) {
            return dayStart(Int(iso[1])!, Int(iso[2])! - 1, Int(iso[3])!)
        }
        if let slash = firstMatch(text, #"^(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})$"#) {
            let year = slash[3].count == 2 ? Int("20\(slash[3])")! : Int(slash[3])!
            let first = Int(slash[1])!
            let second = Int(slash[2])!
            let month = (dateOrder == "dmy" ? second : first) - 1
            let day = dateOrder == "dmy" ? first : second
            return dayStart(year, month, day)
        }
        return nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let part = match.range(at: index)
            guard part.location != NSNotFound, let slice = Range(part, in: text) else { return "" }
            return String(text[slice])
        }
    }

    private static func dayStart(_ year: Int, _ month: Int, _ day: Int) -> TimeInterval {
        var parts = DateComponents()
        parts.year = year
        parts.month = month + 1
        parts.day = day
        let date = Calendar.current.date(from: parts) ?? Date()
        return Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000
    }

    private static func yearsBack(_ month: Int, _ day: Int, _ now: TimeInterval) -> TimeInterval {
        let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: now / 1000))
        let candidate = dayStart(year, month, day)
        if candidate > startOfDay(now) + 2 * 86_400_000 { return dayStart(year - 1, month, day) }
        return candidate
    }

    private static func weekdayIndex(_ text: String) -> Int? {
        if let english = weekdays.firstIndex(of: text.lowercased()) { return english }
        if let zh = weekdaysZh.firstIndex(of: text) { return zh }
        if text == "星期天" || text == "周日" { return 0 }
        let short = ["周一", "周二", "周三", "周四", "周五", "周六"]
        if let index = short.firstIndex(of: text) { return index + 1 }
        return nil
    }
}

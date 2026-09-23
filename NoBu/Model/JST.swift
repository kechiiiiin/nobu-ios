import Foundation

/// 読書の日付は JST の日付（'YYYY-MM-DD'）で扱う。Worker の `shared/dates.ts` と同じ約束。
enum JST {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// その時点の JST の日付
    static func today(_ now: Date = Date()) -> String { dayFormatter.string(from: now) }

    /// 'YYYY-MM-DD' → JST のその日の 12:00（DatePicker に渡す用。日付の端で前後しないよう正午にする）
    static func date(from day: String) -> Date? {
        guard let d = dayFormatter.date(from: day) else { return nil }
        return calendar.date(byAdding: .hour, value: 12, to: d) ?? d
    }

    static func day(from date: Date) -> String { dayFormatter.string(from: date) }

    /// 日付に n 日足す
    static func addDays(_ day: String, _ n: Int) -> String {
        guard let d = dayFormatter.date(from: day), let moved = calendar.date(byAdding: .day, value: n, to: d) else { return day }
        return dayFormatter.string(from: moved)
    }

    /// 両端を含む日数（9/10〜9/23 → 14）
    static func daysInclusive(from: String, to: String) -> Int {
        guard let a = dayFormatter.date(from: from), let b = dayFormatter.date(from: to) else { return 0 }
        return (calendar.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }

    /// ISO8601 の日時（サーバーの `created_at` など）→ JST の日付。日付だけならそのまま
    static func jstDate(_ iso: String) -> String {
        if iso.count == 10 { return iso }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = parser.date(from: iso) { return dayFormatter.string(from: d) }
        parser.formatOptions = [.withInternetDateTime]
        if let d = parser.date(from: iso) { return dayFormatter.string(from: d) }
        return String(iso.prefix(10))
    }

    /// 「今日（2026-09-23）」「昨日（…）」「2026-09-01」
    static func friendly(_ day: String, today: String = JST.today()) -> String {
        if day == today { return "今日（\(day)）" }
        if day == addDays(today, -1) { return "昨日（\(day)）" }
        return day
    }
}

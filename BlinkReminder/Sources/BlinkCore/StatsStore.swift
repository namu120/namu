import Foundation

/// 1분 단위 집계. `activeSeconds` 는 그 1분 동안 얼굴이 보여 감지가 돌아간 시간.
public struct MinuteStats: Codable, Equatable {
    public var blinks: Int = 0
    public var activeSeconds: Double = 0
    public init(blinks: Int = 0, activeSeconds: Double = 0) {
        self.blinks = blinks
        self.activeSeconds = activeSeconds
    }
}

/// 하루치 통계. `minutes` 는 "분 번호(0~1439)" 문자열 → MinuteStats (활동이 있던 분만 존재).
public struct DayStats: Codable, Equatable {
    public var minutes: [String: MinuteStats] = [:]
    public var overlayTriggers: Int = 0
    public var notifications: Int = 0
    public var longestGap: Double = 0

    public init() {}

    public var totalBlinks: Int { minutes.values.reduce(0) { $0 + $1.blinks } }
    public var activeSeconds: Double { minutes.values.reduce(0) { $0 + $1.activeSeconds } }
    /// 활동 1분당 깜빡임. 활동이 1분 미만이면 nil.
    public var blinksPerMinute: Double? {
        let s = activeSeconds
        return s >= 60 ? Double(totalBlinks) / (s / 60) : nil
    }

    public struct HourStats: Equatable {
        public var hour: Int
        public var blinks: Int
        public var activeSeconds: Double
        public var blinksPerMinute: Double? { activeSeconds >= 60 ? Double(blinks) / (activeSeconds / 60) : nil }
    }

    /// 시간대별(0~23) 집계. 활동이 전혀 없던 시간은 activeSeconds 0.
    public var hourly: [HourStats] {
        var hours = (0..<24).map { HourStats(hour: $0, blinks: 0, activeSeconds: 0) }
        for (key, m) in minutes {
            guard let minute = Int(key), (0..<1440).contains(minute) else { continue }
            hours[minute / 60].blinks += m.blinks
            hours[minute / 60].activeSeconds += m.activeSeconds
        }
        return hours
    }
}

/// 날짜별 통계를 메모리에 모았다가 JSON 파일로 저장한다. 메인 스레드에서만 쓴다.
public final class StatsStore {
    public private(set) var days: [String: DayStats] = [:]
    public let url: URL
    public var calendar: Calendar
    public var retentionDays = 400
    private var dirty = false

    public init(url: URL, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
    }

    // MARK: 키

    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: 기록

    private func mutate(_ date: Date, _ body: (inout DayStats) -> Void) {
        var day = days[dayKey(date)] ?? DayStats()
        body(&day)
        days[dayKey(date)] = day
        dirty = true
    }

    private func mutateMinute(_ date: Date, _ body: (inout MinuteStats) -> Void) {
        mutate(date) { day in
            let key = String(minuteOfDay(date))
            var m = day.minutes[key] ?? MinuteStats()
            body(&m)
            day.minutes[key] = m
        }
    }

    public func record(blinks: Int, at date: Date) {
        guard blinks > 0 else { return }
        mutateMinute(date) { $0.blinks += blinks }
    }

    public func recordActive(seconds: Double, at date: Date) {
        guard seconds > 0 else { return }
        mutateMinute(date) { $0.activeSeconds += seconds }
    }

    public func recordOverlayTrigger(at date: Date) {
        mutate(date) { $0.overlayTriggers += 1 }
    }

    public func recordNotification(at date: Date) {
        mutate(date) { $0.notifications += 1 }
    }

    public func recordGap(_ seconds: Double, at date: Date) {
        guard seconds > (days[dayKey(date)]?.longestGap ?? 0) else { return }
        mutate(date) { $0.longestGap = seconds }
    }

    // MARK: 조회

    public func day(_ date: Date) -> DayStats {
        days[dayKey(date)] ?? DayStats()
    }

    /// 오늘을 포함해 최근 n일 (오래된 날부터). 기록이 없는 날은 빈 DayStats.
    public func lastDays(_ n: Int, endingAt date: Date) -> [(date: Date, stats: DayStats)] {
        let today = calendar.startOfDay(for: date)
        return (0..<n).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (d, day(d))
        }
    }

    // MARK: 저장/불러오기

    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        days = try JSONDecoder().decode([String: DayStats].self, from: data)
        dirty = false
    }

    @discardableResult
    public func saveIfNeeded(now: Date = Date()) throws -> Bool {
        guard dirty else { return false }
        prune(now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(days).write(to: url, options: .atomic)
        dirty = false
        return true
    }

    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoffKey = dayKey(cutoff)
        days = days.filter { $0.key >= cutoffKey }
    }

    // MARK: 내보내기

    public func csv() -> String {
        var lines = ["date,blinks,active_minutes,blinks_per_minute,overlay_triggers,notifications,longest_gap_seconds"]
        for key in days.keys.sorted() {
            let d = days[key]!
            let rate = d.blinksPerMinute.map { String(format: "%.1f", $0) } ?? ""
            lines.append("\(key),\(d.totalBlinks),\(String(format: "%.1f", d.activeSeconds / 60)),\(rate),\(d.overlayTriggers),\(d.notifications),\(String(format: "%.0f", d.longestGap))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

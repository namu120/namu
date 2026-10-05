import XCTest
@testable import BlinkCore

final class BlinkTrackerTests: XCTestCase {
    func testHysteresisCountsOneBlink() {
        let t = BlinkTracker(closeThreshold: 0.5, openThreshold: 0.3, now: 100)
        let seq: [(Double, Double)] = [(0.0, 0.05), (0.1, 0.05), (0.2, 0.7), (0.3, 0.9), (0.4, 0.4), (0.5, 0.2), (0.6, 0.05)]
        var blinks = 0
        for (dt, s) in seq where t.update(score: s, now: 100 + dt) { blinks += 1 }
        XCTAssertEqual(blinks, 1)
        XCTAssertEqual(t.snapshot(now: 100.6).totalBlinks, 1)
        XCTAssertEqual(t.snapshot(now: 100.6).lastBlink, 100.5, accuracy: 1e-9)
        XCTAssertEqual(t.blinks(inLast: 60, now: 100.6), 1)
        XCTAssertEqual(t.blinks(inLast: 60, now: 160.6), 0)
    }

    func testMidZoneKeepsState() {
        let t = BlinkTracker(now: 0)
        t.update(score: 0.4, now: 1)            // 0.3~0.5 사이: 뜸 유지
        XCTAssertFalse(t.snapshot(now: 1).closed)
        t.update(score: 0.8, now: 2)
        t.update(score: 0.4, now: 3)            // 감김 유지
        XCTAssertTrue(t.snapshot(now: 3).closed)
        XCTAssertEqual(t.snapshot(now: 3).totalBlinks, 0)
    }

    func testFaceLossResetsTimerAndState() {
        let t = BlinkTracker(now: 0)
        t.update(score: 0.9, now: 1)
        t.update(score: nil, now: 20)
        let s = t.snapshot(now: 20)
        XCTAssertFalse(s.faceVisible)
        XCTAssertFalse(s.closed)
        XCTAssertEqual(s.lastBlink, 20)
        t.update(score: 0.05, now: 21)          // 다시 나타나도 깜빡임으로 세지 않음
        XCTAssertEqual(t.snapshot(now: 21).totalBlinks, 0)
    }

    func testLongestGapAndHistory() {
        let t = BlinkTracker(now: 0)
        for (open, close) in [(10.0, 10.2), (25.0, 25.2), (100.0, 100.2)] {
            t.update(score: 0.9, now: open)
            t.update(score: 0.1, now: close)
        }
        XCTAssertEqual(t.snapshot(now: 101).longestGap, 75.0, accuracy: 1e-9)
        // now=101 기준: 10.2s, 25.2s 는 둘 다 '1~2분 전' 칸, 100.2s 는 '현재 1분' 칸
        XCTAssertEqual(t.perMinuteHistory(minutes: 3, now: 101), [0, 2, 1])
        XCTAssertEqual(t.perMinuteHistory(minutes: 1, now: 101), [1])
        XCTAssertEqual(t.perMinuteHistory(minutes: 2, now: 130), [2, 1])
    }
}

final class EyeMetricsTests: XCTestCase {
    func testHexagonEyeMatchesClassicEAR() {
        // 눈꼬리 (0,0),(4,0), 위 (1,1),(3,1), 아래 (1,-1),(3,-1) → 고전 EAR = (2+2)/(2*4) = 0.5
        let pts = [(0, 0), (1, 1), (3, 1), (4, 0), (3, -1), (1, -1)].map { EyeMetrics.Point(Double($0.0), Double($0.1)) }
        XCTAssertEqual(EyeMetrics.aspectRatio(pts)!, 0.5, accuracy: 1e-9)
        // 회전해도 같은 값
        let a = 0.7
        let rot = pts.map { EyeMetrics.Point($0.x * cos(a) - $0.y * sin(a), $0.x * sin(a) + $0.y * cos(a)) }
        XCTAssertEqual(EyeMetrics.aspectRatio(rot)!, 0.5, accuracy: 1e-9)
    }

    func testClosedEyeHasLowEAR() {
        let pts = [(0, 0), (1, 0.1), (3, 0.1), (4, 0), (3, -0.1), (1, -0.1)].map { EyeMetrics.Point($0.0, $0.1) }
        XCTAssertEqual(EyeMetrics.aspectRatio(pts)!, 0.05, accuracy: 1e-9)
        XCTAssertNil(EyeMetrics.aspectRatio([EyeMetrics.Point(0, 0), EyeMetrics.Point(1, 1)]))
    }

    func testClosureScore() {
        XCTAssertEqual(EyeMetrics.closureScore(ear: 0.35, open: 0.30, closed: 0.12), 0)
        XCTAssertEqual(EyeMetrics.closureScore(ear: 0.05, open: 0.30, closed: 0.12), 1)
        XCTAssertEqual(EyeMetrics.closureScore(ear: 0.21, open: 0.30, closed: 0.12), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EyeMetrics.closureScore(ear: 0.2, open: 0.1, closed: 0.3), 0)   // 잘못된 기준은 0
    }
}

final class NtfyClientTests: XCTestCase {
    func testRequestPostsToTopicWithHeaders() throws {
        let c = NtfyClient(server: "https://ntfy.sh ", topic: " my-topic ")
        let req = try c.makeRequest(title: "제목", message: "본문 내용", priority: 9, tags: ["eye"])
        XCTAssertEqual(req.url?.absoluteString, "https://ntfy.sh/my-topic")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(String(data: try XCTUnwrap(req.httpBody), encoding: .utf8), "본문 내용")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Priority"), "5")          // 1~5 로 클램프
        XCTAssertEqual(req.value(forHTTPHeaderField: "Tags"), "eye")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Title"), "=?UTF-8?B?7KCc66qp?=")   // "제목" RFC 2047
        XCTAssertEqual(NtfyClient.headerValue("Blink!"), "Blink!")
    }

    func testServerFieldTolerance() throws {
        // 서버 칸에 주제까지 붙여 넣은 경우: 호스트만 쓰고, 주제 칸이 비었으면 경로를 주제로
        let full = try NtfyClient(server: "https://ntfy.sh/blink-abc", topic: "").resolved()
        XCTAssertEqual(full.base.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(full.topic, "blink-abc")
        let both = try NtfyClient(server: "https://ntfy.sh/blink-abc", topic: "other").resolved()
        XCTAssertEqual(both.topic, "other")
        let noScheme = try NtfyClient(server: "ntfy.example.com:8080", topic: "t").resolved()
        XCTAssertEqual(noScheme.base.absoluteString, "https://ntfy.example.com:8080")
        let empty = try NtfyClient(server: "", topic: "t").resolved()
        XCTAssertEqual(empty.base.absoluteString, "https://ntfy.sh")
    }

    func testValidation() {
        XCTAssertThrowsError(try NtfyClient(server: "https://ntfy.sh", topic: "").makeRequest(title: "", message: "", priority: 3, tags: []))
        XCTAssertThrowsError(try NtfyClient(server: "ftp://ntfy.sh", topic: "t").makeRequest(title: "", message: "", priority: 3, tags: []))
        let t = NtfyClient.randomTopic()
        XCTAssertTrue(t.hasPrefix("blink-"))
        XCTAssertEqual(t.count, 26)
        XCTAssertNotEqual(t, NtfyClient.randomTopic())
    }
}

final class OverlayPolicyTests: XCTestCase {
    var settings = BlinkSettings()   // limit 7, ramp 4, max 0.85, fade 0.2

    func snap(since: Double, now: Double, visible: Bool = true, closed: Bool = false, stale: Double = 0) -> BlinkTracker.Snapshot {
        BlinkTracker.Snapshot(closed: closed, faceVisible: visible, lastScore: 0, lastBlink: now - since,
                              lastUpdate: now - stale, totalBlinks: 0, longestGap: 0, secondsSinceBlink: since)
    }

    func testProgress() {
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 5, now: 100), now: 100, settings: settings), 0)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 7, now: 100), now: 100, settings: settings), 0)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 9, now: 100), now: 100, settings: settings), 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 20, now: 100), now: 100, settings: settings), 1)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 20, now: 100, closed: true), now: 100, settings: settings), 0)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 20, now: 100, visible: false), now: 100, settings: settings), 0)
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 20, now: 100, stale: 5), now: 100, settings: settings), 0)
        settings.rampSeconds = 0
        XCTAssertEqual(OverlayPolicy.progress(snapshot: snap(since: 7.1, now: 100), now: 100, settings: settings), 1)
    }

    func testEasedAndStep() {
        XCTAssertEqual(OverlayPolicy.eased(0), 0)
        XCTAssertEqual(OverlayPolicy.eased(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayPolicy.eased(1), 1)
        XCTAssertEqual(OverlayPolicy.targetAlpha(progress: 1, settings: settings), 0.85)
        // 올라갈 땐 즉시, 내려갈 땐 fadeOut(0.2s) 안에 0 으로: 0.1s 에 절반
        XCTAssertEqual(OverlayPolicy.step(current: 0.2, target: 0.5, dt: 0.03, settings: settings), 0.5)
        XCTAssertEqual(OverlayPolicy.step(current: 0.85, target: 0, dt: 0.1, settings: settings), 0.425, accuracy: 1e-9)
        XCTAssertEqual(OverlayPolicy.step(current: 0.1, target: 0, dt: 0.1, settings: settings), 0)
        XCTAssertEqual(OverlayPolicy.breathing(elapsed: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(OverlayPolicy.breathing(elapsed: 1.3), 0.9, accuracy: 1e-9)
    }
}

final class StatsStoreTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    func makeStore() -> StatsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blink-stats-\(UUID().uuidString)/stats.json")
        return StatsStore(url: url, calendar: cal)
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testKeysAndMinutes() {
        let s = makeStore()
        XCTAssertEqual(s.dayKey(date(2026, 10, 5, 23, 59)), "2026-10-05")
        XCTAssertEqual(s.minuteOfDay(date(2026, 10, 5, 13, 7)), 13 * 60 + 7)
        XCTAssertEqual(s.date(fromKey: "2026-10-05"), date(2026, 10, 5))
    }

    func testRecordAndRates() {
        let s = makeStore()
        let t = date(2026, 10, 5, 14, 30)
        s.recordActive(seconds: 120, at: t)
        s.record(blinks: 30, at: t)
        s.record(blinks: 0, at: t)
        s.recordActive(seconds: 60, at: date(2026, 10, 5, 15, 0))
        s.record(blinks: 6, at: date(2026, 10, 5, 15, 0))
        s.recordOverlayTrigger(at: t)
        s.recordGap(12, at: t)
        s.recordGap(8, at: t)                       // 더 짧으면 무시
        let day = s.day(t)
        XCTAssertEqual(day.totalBlinks, 36)
        XCTAssertEqual(day.activeSeconds, 180)
        XCTAssertEqual(day.blinksPerMinute!, 12, accuracy: 1e-9)
        XCTAssertEqual(day.overlayTriggers, 1)
        XCTAssertEqual(day.longestGap, 12)
        let h = day.hourly
        XCTAssertEqual(h[14].blinks, 30)
        XCTAssertEqual(h[14].blinksPerMinute!, 15, accuracy: 1e-9)
        XCTAssertEqual(h[15].blinks, 6)
        XCTAssertNil(h[16].blinksPerMinute)
        XCTAssertNil(s.day(date(2026, 10, 4)).blinksPerMinute)
        let week = s.lastDays(7, endingAt: t)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last!.date, date(2026, 10, 5))
        XCTAssertEqual(week.first!.date, date(2026, 9, 29))
        XCTAssertEqual(week.last!.stats.totalBlinks, 36)
    }

    func testSaveLoadAndCSV() throws {
        let s = makeStore()
        let t = date(2026, 10, 5, 9, 0)
        XCTAssertFalse(try s.saveIfNeeded(now: t))     // 변경 없으면 저장 안 함
        s.recordActive(seconds: 60, at: t)
        s.record(blinks: 10, at: t)
        XCTAssertTrue(try s.saveIfNeeded(now: t))
        let s2 = StatsStore(url: s.url, calendar: cal)
        try s2.load()
        XCTAssertEqual(s2.days, s.days)
        XCTAssertEqual(s2.csv(), "date,blinks,active_minutes,blinks_per_minute,overlay_triggers,notifications,longest_gap_seconds\n2026-10-05,10,1.0,10.0,0,0,0\n")
        // 보존 기간이 지난 날은 저장할 때 정리
        s.recordActive(seconds: 60, at: date(2024, 1, 1))
        try s.saveIfNeeded(now: t)
        XCTAssertNil(s.days["2024-01-01"])
        XCTAssertNotNil(s.days["2026-10-05"])
    }
}

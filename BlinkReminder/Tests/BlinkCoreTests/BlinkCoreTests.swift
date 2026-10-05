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
        XCTAssertEqual(t.perMinuteHistory(minutes: 3, now: 101), [1, 1, 1])
        XCTAssertEqual(t.perMinuteHistory(minutes: 1, now: 101), [1])
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
    func testRequestIsJSONPublishToServerRoot() throws {
        let c = NtfyClient(server: "https://ntfy.sh ", topic: " my-topic ")
        let req = try c.makeRequest(title: "제목", message: "본문", priority: 9, tags: ["eye"])
        XCTAssertEqual(req.url?.absoluteString, "https://ntfy.sh")
        XCTAssertEqual(req.httpMethod, "POST")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["topic"] as? String, "my-topic")
        XCTAssertEqual(json["title"] as? String, "제목")
        XCTAssertEqual(json["priority"] as? Int, 5)      // 1~5 로 클램프
        XCTAssertEqual(json["tags"] as? [String], ["eye"])
    }

    func testValidation() {
        XCTAssertThrowsError(try NtfyClient(server: "https://ntfy.sh", topic: "").makeRequest(title: "", message: "", priority: 3, tags: []))
        XCTAssertThrowsError(try NtfyClient(server: "ntfy.sh", topic: "t").makeRequest(title: "", message: "", priority: 3, tags: []))
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

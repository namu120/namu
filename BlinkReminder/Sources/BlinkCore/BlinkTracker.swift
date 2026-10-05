import Foundation

/// 감김 점수(0~1)에 히스테리시스를 적용해 깜빡임을 세고 '마지막 깜빡임' 타이머와 통계를 관리한다.
/// 카메라 스레드가 `update` 를, UI 스레드가 `snapshot` 을 호출한다 (NSLock 으로 보호).
public final class BlinkTracker: @unchecked Sendable {
    public struct Snapshot: Equatable {
        public var closed: Bool
        public var faceVisible: Bool
        public var lastScore: Double?
        public var lastBlink: TimeInterval
        public var lastUpdate: TimeInterval
        public var totalBlinks: Int
        public var longestGap: TimeInterval
        public var secondsSinceBlink: TimeInterval
    }

    public var closeThreshold: Double {
        get { lock.locked { _close } }
        set { lock.locked { _close = newValue } }
    }
    public var openThreshold: Double {
        get { lock.locked { _open } }
        set { lock.locked { _open = newValue } }
    }

    private let lock = NSLock()
    private var _close: Double
    private var _open: Double
    private var closed = false
    private var faceVisible = false
    private var lastScore: Double?
    private var lastBlink: TimeInterval
    private var lastUpdate: TimeInterval
    private var totalBlinks = 0
    private var longestGap: TimeInterval = 0
    /// 최근 1시간의 깜빡임 시각 (오래된 순)
    private var blinkTimes: [TimeInterval] = []

    public init(closeThreshold: Double = 0.5, openThreshold: Double = 0.3, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        precondition(openThreshold < closeThreshold, "openThreshold 는 closeThreshold 보다 작아야 합니다")
        _close = closeThreshold
        _open = openThreshold
        lastBlink = now
        lastUpdate = now
    }

    /// 일시정지/재개 등에서 타이머와 상태를 초기화한다 (누적 통계는 유지).
    public func reset(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.locked {
            closed = false
            faceVisible = false
            lastScore = nil
            lastBlink = now
            lastUpdate = now
        }
    }

    /// score: 감김 점수 0(뜸)~1(감김). 얼굴이 없으면 nil. 깜빡임이 셈해지면 true.
    @discardableResult
    public func update(score: Double?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.locked {
            lastUpdate = now
            lastScore = score
            faceVisible = score != nil
            guard let score else {
                closed = false          // 얼굴이 사라지면 상태 초기화 (유령 깜빡임 방지)
                lastBlink = now         // 타이머 리셋
                return false
            }
            var blinked = false
            if !closed && score > _close {
                closed = true
            } else if closed && score < _open {
                closed = false
                blinked = true
                totalBlinks += 1
                longestGap = max(longestGap, now - lastBlink)
                lastBlink = now
                blinkTimes.append(now)
                let cutoff = now - 3600
                if let first = blinkTimes.firstIndex(where: { $0 >= cutoff }) {
                    blinkTimes.removeFirst(first)
                } else {
                    blinkTimes.removeAll()
                }
            }
            // 감겨 있는 동안은 오버레이 정책이 `closed` 를 보고 끄므로 여기서 타이머를 건드릴 필요가 없다.
            return blinked
        }
    }

    public func blinks(inLast seconds: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        lock.locked { blinkTimes.filter { $0 >= now - seconds }.count }
    }

    /// 최근 `minutes` 분의 분당 깜빡임 횟수. 오래된 분부터, 마지막 원소가 현재 진행 중인 1분.
    public func perMinuteHistory(minutes: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Int] {
        lock.locked {
            var buckets = [Int](repeating: 0, count: max(minutes, 1))
            for t in blinkTimes {
                let age = now - t
                guard age >= 0 else { continue }
                let idx = buckets.count - 1 - Int(age / 60)
                if idx >= 0 { buckets[idx] += 1 }
            }
            return buckets
        }
    }

    public func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.locked {
            Snapshot(
                closed: closed,
                faceVisible: faceVisible,
                lastScore: lastScore,
                lastBlink: lastBlink,
                lastUpdate: lastUpdate,
                totalBlinks: totalBlinks,
                longestGap: longestGap,
                secondsSinceBlink: now - lastBlink
            )
        }
    }
}

public extension NSLock {
    /// Foundation 의 withLock 과 이름이 겹치지 않도록 별도 이름을 쓴다 (Linux Foundation 호환).
    @inline(__always)
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

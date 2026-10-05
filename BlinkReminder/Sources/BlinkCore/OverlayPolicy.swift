import Foundation

/// 트래커 상태로부터 오버레이가 지금 얼마나 어두워야 하는지 결정한다.
public enum OverlayPolicy {
    /// 감지 스레드 갱신이 이 시간(초) 이상 끊기면 오버레이를 끈다
    public static let staleAfter: TimeInterval = 1.0

    /// 0~1 진행도. LIMIT 전 0, LIMIT+RAMP 후 1. 얼굴 없음 / 눈 감김 / 감지 멈춤이면 0.
    public static func progress(snapshot s: BlinkTracker.Snapshot, now: TimeInterval, settings: BlinkSettings) -> Double {
        guard s.faceVisible, !s.closed, now - s.lastUpdate <= staleAfter else { return 0 }
        let since = now - s.lastBlink
        guard since > settings.limitSeconds else { return 0 }
        guard settings.rampSeconds > 0 else { return 1 }
        return min(1, (since - settings.limitSeconds) / settings.rampSeconds)
    }

    /// smoothstep: 시작과 끝이 부드러운 S 커브
    public static func eased(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    public static func targetAlpha(progress: Double, settings: BlinkSettings) -> Double {
        settings.maxAlpha * eased(progress)
    }

    /// 한 틱 적용. 올라갈 때는 target 을 그대로 따르고(RAMP 가 속도를 정함),
    /// 내려갈 때는 fadeOut 시간 안에 0 이 되는 속도로 내려간다.
    public static func step(current: Double, target: Double, dt: TimeInterval, settings: BlinkSettings) -> Double {
        if target >= current { return target }
        let rate = settings.maxAlpha / max(settings.fadeOutSeconds, 0.001)
        return max(target, current - rate * dt)
    }

    /// 완전히 어두워진 뒤 숨쉬듯 맥동하는 계수 (0.9~1.0). period 초 주기.
    public static func breathing(elapsed: TimeInterval, period: TimeInterval = 2.6, depth: Double = 0.1) -> Double {
        1 - depth * (0.5 - 0.5 * cos(2 * .pi * elapsed / period))
    }
}

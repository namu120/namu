import Foundation
import BlinkCore

/// 카메라 스레드에서 프레임을 받아 트래커를 갱신한다. 메인 액터와 분리해 두어 프레임마다 디스패치하지 않는다.
/// 락으로 보호되므로 스레드 간 공유해도 안전하다.
final class FrameProcessor: @unchecked Sendable {
    struct Debug: Equatable {
        var leftEAR: Double?
        var rightEAR: Double?
        var score: Double?
        var faceFound = false
    }

    let tracker: BlinkTracker
    private let lock = NSLock()
    private var earOpen: Double
    private var earClosed: Double
    private var latest = Debug()

    init(tracker: BlinkTracker, earOpen: Double, earClosed: Double) {
        self.tracker = tracker
        self.earOpen = earOpen
        self.earClosed = earClosed
    }

    func setEARRange(open: Double, closed: Double) {
        lock.locked {
            earOpen = open
            earClosed = closed
        }
    }

    var debug: Debug {
        lock.locked { latest }
    }

    func handle(_ frame: CameraService.Frame) {
        let (open, closed) = lock.locked { (earOpen, earClosed) }
        let ears = [frame.leftEAR, frame.rightEAR].compactMap { $0 }
        let ear = ears.isEmpty ? nil : ears.reduce(0, +) / Double(ears.count)
        let score = (frame.faceFound ? ear : nil).map { EyeMetrics.closureScore(ear: $0, open: open, closed: closed) }
        tracker.update(score: score, now: frame.timestamp)
        lock.locked {
            latest = Debug(leftEAR: frame.leftEAR, rightEAR: frame.rightEAR, score: score, faceFound: frame.faceFound)
        }
    }
}

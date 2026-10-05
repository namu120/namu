import Foundation

/// 눈 윤곽 점들로부터 눈 종횡비(EAR, Eye Aspect Ratio)를 계산한다.
/// Apple Vision 의 눈 랜드마크(6~8점)나 다른 어떤 윤곽 점 집합에도 쓸 수 있다.
public enum EyeMetrics {
    public struct Point: Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// 회전 불변 EAR. 가장 멀리 떨어진 두 점을 눈꼬리로 잡고, 나머지 점들이 그 선에서 떨어진
    /// 평균 거리 × 2 를 눈 높이로 본다. 고전적인 EAR (|p2-p6|+|p3-p5|)/(2|p1-p4|) 와 같은 값.
    /// 뜬 눈 ≈ 0.25~0.35, 감은 눈 ≈ 0.05~0.12.
    public static func aspectRatio(_ points: [Point]) -> Double? {
        guard points.count >= 4 else { return nil }
        var a = 0, b = 1, width = -1.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if d > width { (a, b, width) = (i, j, d) }
            }
        }
        guard width > 1e-9 else { return nil }
        let p = points[a], q = points[b]
        let dx = q.x - p.x, dy = q.y - p.y
        var sum = 0.0
        var n = 0
        for (k, r) in points.enumerated() where k != a && k != b {
            sum += abs(dx * (r.y - p.y) - dy * (r.x - p.x)) / width   // 점-직선 거리
            n += 1
        }
        guard n > 0 else { return nil }
        return (sum / Double(n)) * 2 / width
    }

    /// EAR → 감김 점수 0(뜸)~1(감김). 두 기준 사이는 선형.
    public static func closureScore(ear: Double, open: Double, closed: Double) -> Double {
        guard open > closed else { return 0 }
        return min(1, max(0, (open - ear) / (open - closed)))
    }
}

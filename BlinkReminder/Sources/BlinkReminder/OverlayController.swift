import AppKit
import QuartzCore
import BlinkCore

/// 모든 모니터에 borderless·투명·클릭 통과·최상위 창을 띄우고, 비네팅을 그린다.
/// 강도는 창 alpha 로, 띠의 폭은 progress 로 조절한다 (어두워질수록 안쪽으로 번진다).
final class OverlayController {
    private var windows: [NSWindow] = []
    private var views: [VignetteView] = []
    private var lastAlpha = -1.0
    private var lastProgress = -1.0

    func rebuild(settings: BlinkSettings) {
        for w in windows { w.orderOut(nil) }
        windows = []
        views = []
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true                          // 클릭 통과
            window.level = .screenSaver                               // 최상위
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.alphaValue = 0
            let view = VignetteView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.configure(edge: settings.edgeFraction, warm: settings.warmTint)
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        lastAlpha = -1
        lastProgress = -1
    }

    func render(alpha: Double, progress: Double) {
        if alpha != lastAlpha {
            lastAlpha = alpha
            for w in windows { w.alphaValue = CGFloat(alpha) }
        }
        if abs(progress - lastProgress) > 0.002 {
            lastProgress = progress
            for v in views { v.setProgress(progress) }
        }
    }

    func hide() {
        render(alpha: 0, progress: 0)
    }
}

/// 네 변의 선형 그라디언트 띠 + 모서리를 감싸는 부드러운 방사형 비네팅.
final class VignetteView: NSView {
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()
    private let left = CAGradientLayer()
    private let right = CAGradientLayer()
    private let radial = CAGradientLayer()
    private var edge: CGFloat = 0.18
    private var progress: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for g in [top, bottom, left, right] {
            g.type = .axial
            layer?.addSublayer(g)
        }
        radial.type = .radial
        radial.startPoint = CGPoint(x: 0.5, y: 0.5)
        radial.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(radial)
        // 방향: 바깥쪽이 진하고 안쪽이 투명
        top.startPoint = CGPoint(x: 0.5, y: 1); top.endPoint = CGPoint(x: 0.5, y: 0)
        bottom.startPoint = CGPoint(x: 0.5, y: 0); bottom.endPoint = CGPoint(x: 0.5, y: 1)
        left.startPoint = CGPoint(x: 0, y: 0.5); left.endPoint = CGPoint(x: 1, y: 0.5)
        right.startPoint = CGPoint(x: 1, y: 0.5); right.endPoint = CGPoint(x: 0, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    func configure(edge: Double, warm: Bool) {
        self.edge = CGFloat(edge)
        let color = warm ? NSColor(srgbRed: 0.13, green: 0.07, blue: 0.02, alpha: 1) : NSColor.black
        let clear = color.withAlphaComponent(0).cgColor
        for g in [top, bottom, left, right] {
            g.colors = [color.cgColor, color.withAlphaComponent(0.55).cgColor, clear]
            g.locations = [0, 0.45, 1]
        }
        radial.colors = [clear, clear, color.withAlphaComponent(0.75).cgColor]
        radial.locations = [0, 0.55, 1]
        needsLayout = true
    }

    /// progress 0→1 에 따라 띠가 안쪽으로 번진다 (0.75배 → 1.25배).
    func setProgress(_ p: Double) {
        progress = CGFloat(min(1, max(0, p)))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let scale = 0.75 + 0.5 * progress
        let ex = b.width * edge * scale
        let ey = b.height * edge * scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.frame = CGRect(x: 0, y: b.height - ey, width: b.width, height: ey)
        bottom.frame = CGRect(x: 0, y: 0, width: b.width, height: ey)
        left.frame = CGRect(x: 0, y: 0, width: ex, height: b.height)
        right.frame = CGRect(x: b.width - ex, y: 0, width: ex, height: b.height)
        radial.frame = b
        radial.locations = [0, NSNumber(value: Double(0.70 - 0.25 * progress)), 1]
        CATransaction.commit()
    }
}

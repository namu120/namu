import AppKit
import Combine
import ServiceManagement
import SwiftUI
import BlinkCore

enum AppStatus: Equatable {
    case starting
    case cameraDenied
    case cameraError(String)
    case paused
    case noFrames
    case noFace
    case eyesClosed
    case watching

    var text: String {
        switch self {
        case .starting: return "카메라 시작 중"
        case .cameraDenied: return "카메라 권한 없음 · 시스템 설정 > 개인정보 보호 > 카메라"
        case .cameraError(let m): return "카메라 오류: \(m)"
        case .paused: return "일시정지 (카메라 꺼짐)"
        case .noFrames: return "카메라 프레임 없음"
        case .noFace: return "얼굴이 보이지 않음"
        case .eyesClosed: return "눈 감김"
        case .watching: return "감지 중"
        }
    }

    var symbol: String {
        switch self {
        case .watching, .eyesClosed: return "eye"
        case .paused: return "eye.slash"
        case .cameraDenied, .cameraError: return "eye.trianglebadge.exclamationmark"
        default: return "eye.circle"
        }
    }

    var tint: Color {
        switch self {
        case .watching: return .green
        case .eyesClosed, .noFace, .noFrames, .starting: return .orange
        case .paused: return .secondary
        case .cameraDenied, .cameraError: return .red
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let settingsKey = "settings.v1"
    static let historyMinutes = 30

    @Published var settings: BlinkSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var status: AppStatus = .starting
    @Published private(set) var paused = false
    @Published private(set) var blinksLastMinute = 0
    @Published private(set) var blinksPer10MinAvg = 0.0
    @Published private(set) var history: [Int] = Array(repeating: 0, count: AppState.historyMinutes)
    @Published private(set) var sessionTotal = 0
    @Published private(set) var secondsSinceBlink = 0.0
    @Published private(set) var longestGap = 0.0
    @Published private(set) var overlayTriggers = 0
    @Published private(set) var overlayProgress = 0.0
    @Published private(set) var overlayAlpha = 0.0
    @Published private(set) var debug = FrameProcessor.Debug()
    @Published private(set) var cameras: [CameraService.Device] = []
    @Published private(set) var sessionMinutes = 0
    @Published private(set) var loginItemError: String?

    let tracker: BlinkTracker
    private let processor: FrameProcessor
    private let camera = CameraService()
    private let overlay = OverlayController()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastStatsRefresh = 0.0
    private var currentAlpha = 0.0
    private var overlayActive = false
    private var fullyDarkSince: TimeInterval?
    private let sessionStart = ProcessInfo.processInfo.systemUptime
    private var cameraFailure: AppStatus?
    private var screenObserver: Any?

    init() {
        var loaded = Self.loadSettings()
        if loaded.openThreshold >= loaded.closeThreshold {          // 저장값이 깨졌으면 기본값으로
            loaded.closeThreshold = BlinkSettings.default.closeThreshold
            loaded.openThreshold = BlinkSettings.default.openThreshold
        }
        settings = loaded
        tracker = BlinkTracker(closeThreshold: loaded.closeThreshold, openThreshold: loaded.openThreshold)
        processor = FrameProcessor(tracker: tracker, earOpen: loaded.earOpen, earClosed: loaded.earClosed)

        _ = NSApplication.shared.setActivationPolicy(.accessory)      // Dock 아이콘 없음 (Info.plist LSUIElement 와 이중 안전)
        overlay.rebuild(settings: loaded)
        camera.onFrame = { [processor] frame in processor.handle(frame) }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlay.rebuild(settings: self.settings)
            }
        }

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)                       // 메뉴가 열려 있어도 돈다
        timer = t

        Task { await startCamera() }
    }

    // MARK: 설정 저장/적용

    private static func loadSettings() -> BlinkSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(BlinkSettings.self, from: data) else { return .default }
        return s
    }

    private func settingsChanged(from old: BlinkSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if settings.openThreshold < settings.closeThreshold {
            tracker.closeThreshold = settings.closeThreshold
            tracker.openThreshold = settings.openThreshold
        }
        processor.setEARRange(open: settings.earOpen, closed: settings.earClosed)
        if settings.edgeFraction != old.edgeFraction || settings.warmTint != old.warmTint {
            overlay.rebuild(settings: settings)
        }
        if settings.cameraID != old.cameraID || settings.frameRate != old.frameRate, !paused {
            Task { await startCamera() }
        }
    }

    func resetSettings() {
        var s = BlinkSettings.default
        s.cameraID = settings.cameraID
        settings = s
    }

    // MARK: 카메라

    func startCamera() async {
        cameraFailure = nil
        guard await CameraService.requestAccess() else {
            cameraFailure = .cameraDenied
            status = .cameraDenied
            return
        }
        cameras = CameraService.availableCameras()
        do {
            try camera.start(deviceID: settings.cameraID, frameRate: settings.frameRate)
            tracker.reset()
        } catch {
            cameraFailure = .cameraError(error.localizedDescription)
            status = cameraFailure!
        }
    }

    func togglePause() {
        if paused {
            paused = false
            Task { await startCamera() }
        } else {
            paused = true
            camera.stop()                                           // 일시정지 시 카메라 해제
            tracker.reset()
        }
    }

    func quit() {
        camera.stop()
        overlay.hide()
        NSApplication.shared.terminate(nil)
    }

    // MARK: 로그인 시 실행

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: 보정

    /// 지금 보이는 EAR 로 '뜬 눈' 기준을 잡는다 (살짝 여유를 둠).
    func calibrateOpen() {
        guard let ear = currentEAR else { return }
        settings.earOpen = max((ear * 0.9 * 100).rounded() / 100, settings.earClosed + 0.05)
    }

    /// 지금 보이는 EAR 로 '감은 눈' 기준을 잡는다.
    func calibrateClosed() {
        guard let ear = currentEAR else { return }
        settings.earClosed = min((ear * 1.2 * 100).rounded() / 100, settings.earOpen - 0.05)
    }

    var currentEAR: Double? {
        let ears = [debug.leftEAR, debug.rightEAR].compactMap { $0 }
        return ears.isEmpty ? nil : ears.reduce(0, +) / Double(ears.count)
    }

    // MARK: 30Hz 틱

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        let snap = tracker.snapshot(now: now)

        var progress = 0.0
        var target = 0.0
        if !paused && cameraFailure == nil {
            progress = OverlayPolicy.progress(snapshot: snap, now: now, settings: settings)
            target = OverlayPolicy.targetAlpha(progress: progress, settings: settings)
        }
        currentAlpha = OverlayPolicy.step(current: currentAlpha, target: target, dt: dt, settings: settings)

        // 완전히 어두워진 뒤 숨쉬기
        var shown = currentAlpha
        if settings.breathing, progress >= 1, currentAlpha >= target - 1e-6 {
            if fullyDarkSince == nil { fullyDarkSince = now }
            shown *= OverlayPolicy.breathing(elapsed: now - (fullyDarkSince ?? now))
        } else {
            fullyDarkSince = nil
        }
        overlay.render(alpha: shown, progress: progress)

        if target > 0 && !overlayActive { overlayTriggers += 1 }
        overlayActive = target > 0

        // 상태
        let newStatus: AppStatus
        if paused {
            newStatus = .paused
        } else if let failure = cameraFailure {
            newStatus = failure
        } else if now - snap.lastUpdate > OverlayPolicy.staleAfter {
            newStatus = now - sessionStart < 3 ? .starting : .noFrames
        } else if !snap.faceVisible {
            newStatus = .noFace
        } else if snap.closed {
            newStatus = .eyesClosed
        } else {
            newStatus = .watching
        }
        if newStatus != status { status = newStatus }

        if now - lastStatsRefresh >= 0.25 {
            lastStatsRefresh = now
            refreshStats(snap: snap, now: now, progress: progress)
        }
    }

    private func refreshStats(snap: BlinkTracker.Snapshot, now: TimeInterval, progress: Double) {
        blinksLastMinute = tracker.blinks(inLast: 60, now: now)
        let elapsed = max(1, min(600, now - sessionStart))
        blinksPer10MinAvg = Double(tracker.blinks(inLast: 600, now: now)) / elapsed * 60
        history = tracker.perMinuteHistory(minutes: Self.historyMinutes, now: now)
        sessionTotal = snap.totalBlinks
        secondsSinceBlink = snap.faceVisible ? snap.secondsSinceBlink : 0
        longestGap = snap.longestGap
        overlayProgress = progress
        overlayAlpha = currentAlpha
        debug = processor.debug
        sessionMinutes = Int((now - sessionStart) / 60)
    }
}

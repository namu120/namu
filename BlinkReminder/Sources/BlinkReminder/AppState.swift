import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
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
    @Published private(set) var lastNotifyResult: String?
    /// 일별 통계가 바뀔 때마다 증가 (통계 창 갱신용, 최대 1초에 한 번)
    @Published private(set) var statsRevision = 0

    let tracker: BlinkTracker
    let stats: StatsStore
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
    private var lastNotifyAt: TimeInterval = -1e9
    private var notifiedThisEpisode = false
    private var notifySending = false
    private var recordedBlinks = 0
    private var lastActiveRecord: TimeInterval?
    private var lastStatsSave = ProcessInfo.processInfo.systemUptime
    private var lastRevisionBump = 0.0
    private var terminateObserver: Any?

    init() {
        var loaded = Self.loadSettings()
        if loaded.openThreshold >= loaded.closeThreshold {          // 저장값이 깨졌으면 기본값으로
            loaded.closeThreshold = BlinkSettings.default.closeThreshold
            loaded.openThreshold = BlinkSettings.default.openThreshold
        }
        settings = loaded
        tracker = BlinkTracker(closeThreshold: loaded.closeThreshold, openThreshold: loaded.openThreshold)
        processor = FrameProcessor(tracker: tracker, earOpen: loaded.earOpen, earClosed: loaded.earClosed)
        stats = StatsStore(url: Self.statsURL)
        do { try stats.load() } catch { print("[stats] 불러오기 실패: \(error)") }

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

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [stats] _ in
            _ = try? stats.saveIfNeeded()
        }

        Task { await startCamera() }
    }

    static var statsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BlinkReminder/stats.json")
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
        _ = try? stats.saveIfNeeded()
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

    // MARK: iPad 알림 (ntfy)

    func generateTopic() {
        settings.ntfyTopic = NtfyClient.randomTopic()
    }

    func sendTestNotification() {
        sendNotification(test: true)
    }

    private func sendNotification(test: Bool) {
        guard !notifySending else { return }
        notifySending = true
        let client = NtfyClient(server: settings.ntfyServer, topic: settings.ntfyTopic)
        let title = test ? "테스트 · " + settings.notifyTitle : settings.notifyTitle
        let message = settings.notifyMessage
        let priority = settings.notifyPriority
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        Task { [weak self] in
            do {
                try await client.send(title: title, message: message, priority: priority, tags: ["eye"])
                self?.lastNotifyResult = "\(stamp) 전송 완료"
                if !test { self?.stats.recordNotification(at: Date()) }
            } catch {
                self?.lastNotifyResult = "\(stamp) 실패: \(error.localizedDescription)"
            }
            self?.notifySending = false
        }
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

        if target > 0 && !overlayActive {
            overlayTriggers += 1
            stats.recordOverlayTrigger(at: Date())
        }
        overlayActive = target > 0

        // iPad 알림: 완전히 어두워진 순간 한 번, 쿨다운 안에는 다시 보내지 않음
        if progress >= 1 {
            if !notifiedThisEpisode {
                notifiedThisEpisode = true
                if settings.notifyEnabled, now - lastNotifyAt >= settings.notifyCooldownSeconds {
                    lastNotifyAt = now
                    sendNotification(test: false)
                }
            }
        } else if progress == 0 {
            notifiedThisEpisode = false
        }

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
        recordDaily(snap: snap, now: now)
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

    /// 일별 통계 기록: 새 깜빡임, 얼굴이 보인 시간, 최장 공백. 30초마다 디스크에 저장.
    private func recordDaily(snap: BlinkTracker.Snapshot, now: TimeInterval) {
        let wall = Date()
        var changed = false
        let newBlinks = snap.totalBlinks - recordedBlinks
        if newBlinks > 0 {
            stats.record(blinks: newBlinks, at: wall)
            recordedBlinks = snap.totalBlinks
            changed = true
        }
        let active = !paused && snap.faceVisible && now - snap.lastUpdate <= OverlayPolicy.staleAfter
        if active {
            if let last = lastActiveRecord {
                stats.recordActive(seconds: min(now - last, 2), at: wall)
                changed = true
            }
            lastActiveRecord = now
        } else {
            lastActiveRecord = nil
        }
        if snap.longestGap > 0 {
            stats.recordGap(snap.longestGap, at: wall)
        }
        if changed, now - lastRevisionBump >= 1 {
            lastRevisionBump = now
            statsRevision += 1
        }
        if now - lastStatsSave >= 30 {
            lastStatsSave = now
            do { try stats.saveIfNeeded() } catch { print("[stats] 저장 실패: \(error)") }
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "blink-stats.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try stats.csv().write(to: url, atomically: true, encoding: .utf8) } catch { print("[stats] CSV 실패: \(error)") }
    }
}

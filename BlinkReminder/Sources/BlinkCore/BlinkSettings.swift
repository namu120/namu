import Foundation

/// 앱 설정. UserDefaults 에 JSON 으로 저장되며, 키가 없으면 기본값을 쓴다 (버전 호환).
public struct BlinkSettings: Codable, Equatable {
    // ── 타이밍 ──
    /// 마지막 깜빡임 후 이 시간(초)이 지나면 어두워지기 시작
    public var limitSeconds: Double = 7
    /// 0 → maxAlpha 까지 걸리는 시간(초)
    public var rampSeconds: Double = 4
    /// 오버레이 최대 불투명도 (0~1)
    public var maxAlpha: Double = 0.85
    /// 깜빡였을 때 사라지는 시간(초)
    public var fadeOutSeconds: Double = 0.2

    // ── 모양 ──
    /// 가장자리 띠 폭 (화면 비율)
    public var edgeFraction: Double = 0.18
    /// 완전히 어두워진 뒤 천천히 숨쉬듯 맥동
    public var breathing: Bool = true
    /// 검정 대신 따뜻한 암갈색
    public var warmTint: Bool = false
    /// 메뉴바 아이콘 옆에 분당 깜빡임 횟수 표시
    public var showCountInMenuBar: Bool = false
    /// 통계 창에 EAR 원시값 표시
    public var showDebug: Bool = false

    // ── 감지 ──
    /// 감김 점수(0~1)가 이 값 초과 → 감김
    public var closeThreshold: Double = 0.5
    /// 감김 상태에서 이 값 미만 → 뜸 (= 깜빡임 1회)
    public var openThreshold: Double = 0.3
    /// EAR → 감김 점수 변환 기준. EAR ≥ earOpen 이면 0(뜸), EAR ≤ earClosed 이면 1(감김)
    public var earOpen: Double = 0.30
    public var earClosed: Double = 0.12
    /// AVCaptureDevice.uniqueID. nil 이면 기본 카메라
    public var cameraID: String? = nil
    public var frameRate: Int = 15

    // ── iPad 알림 (ntfy) ──
    /// 오버레이가 완전히 어두워지면 ntfy 로 푸시 알림을 보낸다
    public var notifyEnabled: Bool = false
    public var ntfyServer: String = "https://ntfy.sh"
    /// 구독 주제. 사실상 비밀번호 역할이므로 길고 무작위로
    public var ntfyTopic: String = ""
    /// 같은 알림을 다시 보내기까지 최소 간격(초)
    public var notifyCooldownSeconds: Double = 60
    /// ntfy 우선순위 1~5 (3 기본, 4 높음, 5 긴급)
    public var notifyPriority: Int = 4
    public var notifyTitle: String = "눈 깜빡이세요 👁"
    public var notifyMessage: String = "한참 동안 깜빡이지 않았어요. 멀리 한 번 보고 눈을 쉬어 주세요."

    public init() {}
    public static let `default` = BlinkSettings()

    // 키가 빠져 있어도 기본값으로 복원되도록 수동 디코딩
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BlinkSettings.default
        limitSeconds = try c.decodeIfPresent(Double.self, forKey: .limitSeconds) ?? d.limitSeconds
        rampSeconds = try c.decodeIfPresent(Double.self, forKey: .rampSeconds) ?? d.rampSeconds
        maxAlpha = try c.decodeIfPresent(Double.self, forKey: .maxAlpha) ?? d.maxAlpha
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? d.fadeOutSeconds
        edgeFraction = try c.decodeIfPresent(Double.self, forKey: .edgeFraction) ?? d.edgeFraction
        breathing = try c.decodeIfPresent(Bool.self, forKey: .breathing) ?? d.breathing
        warmTint = try c.decodeIfPresent(Bool.self, forKey: .warmTint) ?? d.warmTint
        showCountInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showCountInMenuBar) ?? d.showCountInMenuBar
        showDebug = try c.decodeIfPresent(Bool.self, forKey: .showDebug) ?? d.showDebug
        closeThreshold = try c.decodeIfPresent(Double.self, forKey: .closeThreshold) ?? d.closeThreshold
        openThreshold = try c.decodeIfPresent(Double.self, forKey: .openThreshold) ?? d.openThreshold
        earOpen = try c.decodeIfPresent(Double.self, forKey: .earOpen) ?? d.earOpen
        earClosed = try c.decodeIfPresent(Double.self, forKey: .earClosed) ?? d.earClosed
        cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID)
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? d.frameRate
        notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? d.notifyEnabled
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        notifyCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .notifyCooldownSeconds) ?? d.notifyCooldownSeconds
        notifyPriority = try c.decodeIfPresent(Int.self, forKey: .notifyPriority) ?? d.notifyPriority
        notifyTitle = try c.decodeIfPresent(String.self, forKey: .notifyTitle) ?? d.notifyTitle
        notifyMessage = try c.decodeIfPresent(String.self, forKey: .notifyMessage) ?? d.notifyMessage
    }
}

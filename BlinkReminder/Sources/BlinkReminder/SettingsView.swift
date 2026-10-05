import SwiftUI
import BlinkCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            timingTab.tabItem { Label("타이밍", systemImage: "timer") }
            lookTab.tabItem { Label("모양", systemImage: "circle.lefthalf.filled") }
            detectionTab.tabItem { Label("감지", systemImage: "eye") }
            notifyTab.tabItem { Label("알림", systemImage: "bell.badge") }
            generalTab.tabItem { Label("일반", systemImage: "gear") }
        }
        .frame(width: 440)
        .padding()
    }

    // MARK: 타이밍

    private var timingTab: some View {
        Form {
            slider("어두워지기 시작", value: $state.settings.limitSeconds, range: 3...30, step: 0.5, unit: "초",
                   help: "마지막 깜빡임 후 이 시간이 지나면 가장자리가 어두워지기 시작합니다.")
            slider("완전히 어두워질 때까지", value: $state.settings.rampSeconds, range: 0.5...15, step: 0.5, unit: "초")
            slider("최대 어둡기", value: $state.settings.maxAlpha, range: 0.2...1, step: 0.05, unit: "", percent: true)
            slider("사라지는 시간", value: $state.settings.fadeOutSeconds, range: 0.05...1, step: 0.05, unit: "초",
                   help: "깜빡이면 이 시간 안에 오버레이가 사라집니다.")
        }
        .formStyle(.grouped)
    }

    // MARK: 모양

    private var lookTab: some View {
        Form {
            slider("가장자리 띠 폭", value: $state.settings.edgeFraction, range: 0.05...0.45, step: 0.01, unit: "", percent: true,
                   help: "화면 각 변에서 띠가 차지하는 비율. 어두워질수록 안쪽으로 조금 더 번집니다.")
            Toggle("완전히 어두워진 뒤 숨쉬듯 맥동", isOn: $state.settings.breathing)
            Toggle("따뜻한 색조 (검정 대신 암갈색)", isOn: $state.settings.warmTint)
            Toggle("메뉴바 아이콘 옆에 분당 횟수 표시", isOn: $state.settings.showCountInMenuBar)
        }
        .formStyle(.grouped)
    }

    // MARK: 감지

    private var detectionTab: some View {
        Form {
            Section("눈 종횡비(EAR) 기준") {
                HStack {
                    Text("지금 EAR")
                    Spacer()
                    Text(state.currentEAR.map { String(format: "%.3f", $0) } ?? "얼굴 없음")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(state.currentEAR == nil ? .secondary : .primary)
                }
                slider("뜬 눈 기준", value: $state.settings.earOpen, range: 0.15...0.5, step: 0.01, unit: "",
                       help: "EAR 이 이 값 이상이면 완전히 뜬 눈으로 봅니다.")
                slider("감은 눈 기준", value: $state.settings.earClosed, range: 0.02...0.25, step: 0.01, unit: "",
                       help: "EAR 이 이 값 이하면 완전히 감은 눈으로 봅니다.")
                HStack {
                    Button("지금 뜬 눈으로 보정") { state.calibrateOpen() }
                    Button("지금 감은 눈으로 보정") { state.calibrateClosed() }
                    Spacer()
                }
                .disabled(state.currentEAR == nil)
                Text("카메라를 자연스럽게 보며 '뜬 눈' 보정 → 눈을 감고 1초 뒤 '감은 눈' 보정. 깜빡임이 안 잡히면 '뜬 눈 기준'을 낮추고, 너무 잘 잡히면 올리세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("히스테리시스 (감김 점수 0~1)") {
                slider("감김으로 판정", value: $state.settings.closeThreshold, range: 0.3...0.9, step: 0.05, unit: "")
                slider("뜸으로 판정", value: $state.settings.openThreshold, range: 0.1...0.7, step: 0.05, unit: "")
                if state.settings.openThreshold >= state.settings.closeThreshold {
                    Text("'뜸' 기준은 '감김' 기준보다 작아야 합니다. 적용되지 않습니다.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("카메라") {
                Picker("카메라", selection: Binding(
                    get: { state.settings.cameraID ?? "" },
                    set: { state.settings.cameraID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("기본").tag("")
                    ForEach(state.cameras) { cam in Text(cam.name).tag(cam.id) }
                }
                Picker("감지 프레임레이트", selection: $state.settings.frameRate) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("통계 창에 EAR 원시값 표시", isOn: $state.settings.showDebug)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 알림 (ntfy)

    private var notifyTab: some View {
        Form {
            Section("iPad / iPhone 로 푸시 알림 (ntfy)") {
                Toggle("오버레이가 완전히 어두워지면 알림 보내기", isOn: $state.settings.notifyEnabled)
                TextField("서버", text: $state.settings.ntfyServer, prompt: Text("https://ntfy.sh"))
                HStack {
                    TextField("주제 (topic)", text: $state.settings.ntfyTopic, prompt: Text("blink-xxxxxxxx"))
                        .font(.system(.body, design: .monospaced))
                    Button("무작위 생성") { state.generateTopic() }
                }
                slider("재전송 최소 간격", value: $state.settings.notifyCooldownSeconds, range: 15...600, step: 5, unit: "초",
                       help: "깜빡이지 않는 상태가 이어져도 이 간격 안에는 다시 보내지 않습니다.")
                Picker("우선순위", selection: $state.settings.notifyPriority) {
                    Text("보통 (3)").tag(3)
                    Text("높음 (4)").tag(4)
                    Text("긴급 (5) · 방해금지도 뚫음").tag(5)
                }
                TextField("제목", text: $state.settings.notifyTitle)
                TextField("내용", text: $state.settings.notifyMessage)
                HStack {
                    Button("테스트 알림 보내기") { state.sendTestNotification() }
                        .disabled(state.settings.ntfyTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let r = state.lastNotifyResult {
                        Text(r).font(.caption).foregroundStyle(r.contains("실패") ? Color.red : Color.secondary)
                    }
                }
            }
            Section("iPad 설정 방법") {
                Text("1. App Store 에서 ntfy 앱을 설치합니다.\n2. 앱에서 + 를 눌러 구독을 추가하고, 위 주제 이름을 똑같이 입력합니다.\n3. 여기서 '테스트 알림 보내기'를 눌러 iPad 에 배너가 뜨는지 확인합니다.\n4. 집중 모드를 쓰면 ntfy 를 허용 앱에 넣거나 우선순위를 '긴급'으로 두세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("주제 이름은 아는 사람 누구나 알림을 보낼 수 있는 주소이므로 무작위 이름을 쓰고 공유하지 마세요. ntfy.sh 는 무료 공개 서버이며 직접 호스팅한 서버 주소를 넣어도 됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 일반

    private var generalTab: some View {
        Form {
            Toggle("로그인할 때 자동 실행", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            if let err = state.loginItemError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("앱을 /Applications 또는 ~/Applications 에 두면 자동 실행이 안정적입니다 (build-app.sh --install).")
                .font(.caption).foregroundStyle(.secondary)
            Button("기본값으로 되돌리기") { state.resetSettings() }
            Text("영상은 메모리에서만 처리되며 저장하거나 전송하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("빌드", value: Self.buildStamp)
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    /// build-app.sh 가 CFBundleVersion 에 빌드 시각(YYYYMMDD.HHMM)을 넣는다
    static var buildStamp: String {
        let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(s) (\(v))"
    }

    // MARK: 공통 슬라이더

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, percent: Bool = false, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? String(format: "%.0f%%", value.wrappedValue * 100)
                             : String(format: step < 0.1 ? "%.2f" : "%.1f", value.wrappedValue) + unit)
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

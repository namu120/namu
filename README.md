# namu — 눈 깜빡임 유도 앱 (macOS)

웹캠으로 깜빡임을 감지하다가 일정 시간(기본 7초) 안 깜빡이면 화면 가장자리가 서서히
어두워지고, 깜빡이는 즉시 풀리는 메뉴바(👁) 상주 앱. 영상은 메모리에서만 처리하며 저장·전송하지 않는다.

두 가지 구현이 있다.

| | `BlinkReminder/` (Swift, 네이티브 앱) | `blink_reminder.py` (Python 프로토타입) |
|---|---|---|
| 감지 | Apple Vision 눈 랜드마크 → 눈 종횡비(EAR) | MediaPipe FaceLandmarker blendshapes |
| UI | 메뉴바 통계 창(분당 그래프), 설정 창, 비네팅 애니메이션 | 메뉴바 메뉴, 터미널 디버그 |
| 설치 | `./build-app.sh` 한 번 → .app | venv + pip |

## Swift 앱 (BlinkReminder/)

```bash
cd BlinkReminder
./build-app.sh              # 빌드 + 실행 (Xcode Command Line Tools 필요: xcode-select --install)
./build-app.sh --test       # BlinkCore 테스트까지 돌린 뒤 빌드
./build-app.sh --install    # ~/Applications 에 설치 후 실행 (로그인 시 자동 실행용)
```

- 첫 실행 때 카메라 권한 팝업이 뜬다. 권한은 BlinkReminder 앱 자체에 붙는다.
- 메뉴바 눈 아이콘 → 통계 창: 최근 1분/10분 평균/마지막 깜빡임/최장 공백, 최근 30분 분당 그래프,
  어두워지기까지 남은 시간, 일시정지/설정/종료.
- 설정(⌘,): 타이밍·모양·감지·일반. 감지 탭에서 "지금 EAR" 값을 보며 뜬 눈/감은 눈 기준을 버튼으로 보정할 수 있다.
- 통계 창(메뉴 > 통계…): 하루 평균 깜빡임/분, 활동 시간, 오늘 시간대별 추이를 7/30/90일로 본다.
  분 단위 집계가 `~/Library/Application Support/BlinkReminder/stats.json` 에 쌓이고(400일 보관) CSV 로 내보낼 수 있다.
- iPad/iPhone 알림: 설정 > 알림 탭에서 ntfy 를 켜면 오버레이가 완전히 어두워질 때 푸시 알림을 보낸다.
  iPad 에 App Store 의 ntfy 앱을 설치하고 같은 주제(topic)를 구독하면 GoodNotes 등 어떤 앱 위에서도 배너가 뜬다.
- 구조: `Sources/BlinkCore` 는 플랫폼 독립 로직(히스테리시스, 통계, EAR, 오버레이 정책)이라 iPad 타깃에서 그대로 재사용한다.
  `Sources/BlinkReminder` 가 macOS 전용(AVFoundation + Vision, AppKit 오버레이, SwiftUI 메뉴바/설정).

## Python 프로토타입 (blink_reminder.py)

## 실행

```bash
./run.sh            # venv 생성 + 설치 + 실행을 한 번에 (두 번째부터는 바로 실행)
./run.sh --debug    # 인자는 그대로 blink_reminder.py 로 전달
```

수동으로 하려면 (Python 3.10 ~ 3.12, mediapipe 휠 지원 범위):

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt                       # mediapipe, pyobjc-framework-Cocoa
python blink_reminder.py
```

- 첫 실행 때 `face_landmarker.task` 모델(약 3.7MB)을 `~/.cache/blink_reminder/`에 자동 다운로드한다.
- 처음 한 번 **카메라 권한** 프롬프트가 뜬다. 권한은 터미널 앱(Terminal/iTerm 등)에 붙는다.
  거부했다면 시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 켜 준다.
- Dock 아이콘 없이 메뉴바 👁 아이콘만 생긴다. 메뉴: 최근 1분 깜빡임 횟수 / 상태 /
  일시정지·재개(일시정지 중엔 카메라 해제) / 종료. 터미널에서 Ctrl-C 로도 종료된다.

## 튜닝

```bash
python blink_reminder.py --debug                      # 프레임마다 eyeBlink 점수 출력 → 임계값 튜닝
python blink_reminder.py --limit 10 --ramp 3 --max-alpha 0.7
python blink_reminder.py --close-thresh 0.45 --open-thresh 0.25 --camera 1
python blink_reminder.py --headless --debug           # 오버레이/메뉴바 없이 감지만 (다른 OS 에서도 동작)
python blink_reminder.py --help                       # 전체 옵션
```

기본값은 파일 상단 상수(`LIMIT`, `RAMP`, `MAX_ALPHA`, `CLOSE_THRESH`, `OPEN_THRESH`,
`CAMERA_INDEX` 등)로 바꿔도 된다.

## 동작 요약

- MediaPipe Tasks `FaceLandmarker` (VIDEO 모드, blendshapes) 의 `eyeBlinkLeft/Right` 평균에
  히스테리시스 적용: 0.5 초과 → 감김, 0.3 미만 → 뜸. 감김→뜸 전환이 깜빡임 1회.
- 얼굴이 안 보이거나 눈이 계속 감겨 있으면(아래 보는 중 등) 타이머를 리셋해 오버레이가 뜨지 않는다.
- 카메라 640x480, 약 15fps, 백그라운드 스레드. `VideoCapture` 는 권한 프롬프트 때문에 메인 스레드에서 연다.
- 오버레이: 모든 모니터에 borderless·투명·클릭 통과·최상위·모든 Space/전체화면 창.
  네 가장자리에 검정→투명 그라디언트 띠(화면의 18%)를 그리고 창 alpha 로 강도를 조절한다.
  LIMIT 후 RAMP 동안 0→MAX_ALPHA, 깜빡이면 0.2초 안에 사라진다.

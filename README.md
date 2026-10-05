# namu — 눈 깜빡임 유도 앱 (macOS, 프로토타입)

웹캠으로 깜빡임을 감지하다가 일정 시간(기본 7초) 안 깜빡이면 화면 가장자리가 서서히
어두워지고, 깜빡이는 즉시 풀리는 메뉴바(👁) 상주 앱. 전체가 `blink_reminder.py` 한 파일이다.
영상은 메모리에서만 처리하며 저장·전송하지 않는다.

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

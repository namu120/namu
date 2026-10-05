#!/bin/bash
# macOS: Swift 패키지를 빌드해 BlinkReminder.app 번들을 만들고 실행한다.
#   ./build-app.sh            # 빌드 + 실행
#   ./build-app.sh --test     # 코어 테스트까지 돌린 뒤 빌드 + 실행
#   ./build-app.sh --install  # ~/Applications 에 복사하고 거기서 실행 (로그인 시 자동 실행용)
#   ./build-app.sh --no-run   # 빌드만
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift 가 없습니다. Xcode Command Line Tools 를 설치하세요: xcode-select --install" >&2
  exit 1
fi

RUN=1; INSTALL=0; TEST=0
for arg in "$@"; do
  case "$arg" in
    --no-run) RUN=0 ;;
    --install) INSTALL=1 ;;
    --test) TEST=1 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 1 ;;
  esac
done

if [ "$TEST" = 1 ]; then
  echo "[test] BlinkCore 테스트"
  swift test --filter BlinkCoreTests
fi

echo "[build] swift build -c release (처음엔 1~3분)"
swift build -c release --product BlinkReminder

APP="build/BlinkReminder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/BlinkReminder" "$APP/Contents/MacOS/BlinkReminder"
cp Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  echo "[build] 앱 아이콘 생성"
  swift Tools/make-icon.swift build/AppIcon.icns || echo "[build] 아이콘 생성 실패 (무시)"
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 로컬 실행용 ad-hoc 서명 (카메라 권한을 번들 ID 로 기억하게 해 준다)
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "[build] 완료: $APP"

TARGET="$APP"
if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/BlinkReminder.app"
  cp -R "$APP" "$HOME/Applications/BlinkReminder.app"
  TARGET="$HOME/Applications/BlinkReminder.app"
  echo "[build] 설치: $TARGET"
fi

if [ "$RUN" = 1 ]; then
  pkill -x BlinkReminder >/dev/null 2>&1 || true
  sleep 0.3
  open "$TARGET"
  echo "[build] 실행했습니다. 메뉴바의 눈 아이콘을 확인하세요."
fi

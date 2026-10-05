#!/bin/bash
# macOS: venv 생성 + 의존성 설치 + 실행을 한 번에. 두 번째부터는 설치를 건너뛰고 바로 실행한다.
#   ./run.sh            # 실행
#   ./run.sh --debug    # 점수 출력 (인자는 그대로 blink_reminder.py 로 전달)
set -e
cd "$(dirname "$0")"

# mediapipe 휠이 있는 파이썬(3.10~3.12)을 찾는다
PY=""
for c in python3.12 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null 2>&1; then
    v=$("$c" -c 'import sys; print(sys.version_info[1])')
    if [ "$v" -ge 10 ] && [ "$v" -le 12 ]; then PY="$c"; break; fi
  fi
done
if [ -z "$PY" ]; then
  echo "Python 3.10~3.12 가 필요합니다. 'brew install python@3.12' 후 다시 실행하세요." >&2
  exit 1
fi

if [ ! -x .venv/bin/python ]; then
  echo "[setup] venv 생성 ($PY)"
  "$PY" -m venv .venv
fi
if [ ! -f .venv/.installed ]; then
  echo "[setup] 의존성 설치 (1~2분)"
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
  touch .venv/.installed
fi
exec .venv/bin/python blink_reminder.py "$@"

#!/usr/bin/env python3
"""
blink_reminder.py — macOS 눈 깜빡임 유도 메뉴바 앱 (단일 파일 프로토타입)

웹캠으로 깜빡임을 감지하다가 LIMIT초 동안 깜빡이지 않으면 화면 네 가장자리가
서서히 어두워지고, 깜빡이는 즉시 풀린다. Dock 아이콘 없이 메뉴바(👁)에만 상주한다.
영상은 메모리에서만 처리하며 저장하거나 전송하지 않는다.

    python blink_reminder.py            # 실행
    python blink_reminder.py --debug    # blink 점수를 터미널에 출력 (임계값 튜닝용)
    python blink_reminder.py --help     # 모든 옵션

구조
  BlinkTracker     eyeBlink 점수에 히스테리시스를 적용해 깜빡임을 세고 타이머를 관리 (스레드 안전)
  FaceBlinkScorer  MediaPipe Tasks FaceLandmarker(VIDEO 모드, blendshapes) 래퍼
  CameraWorker     백그라운드 스레드: 카메라 프레임 → 점수 → tracker
  run_app()        PyObjC/AppKit: 오버레이 창 + 메뉴바 (macOS 전용, 함수 안에서만 import)
  run_headless()   오버레이 없이 터미널에서 감지만 (튜닝/다른 OS 테스트용)
"""
from __future__ import annotations

import argparse
import collections
import os
import signal
import sys
import threading
import time
import urllib.request

# ──────────────────────────── 튜닝 상수 (CLI 인자로 덮어쓸 수 있음) ────────────────────────────
LIMIT = 7.0           # 마지막 깜빡임 후 이 시간(초)이 지나면 어두워지기 시작
RAMP = 4.0            # 0 → MAX_ALPHA 까지 걸리는 시간(초)
MAX_ALPHA = 0.85      # 오버레이 최대 불투명도 (0~1)
FADE_OUT = 0.2        # 깜빡였을 때 오버레이가 사라지는 데 걸리는 시간(초)
CLOSE_THRESH = 0.5    # eyeBlink 평균이 이 값을 초과하면 "감김"
OPEN_THRESH = 0.3     # "감김" 상태에서 이 값 미만으로 내려오면 "뜸" → 깜빡임 1회
CAMERA_INDEX = 0
FRAME_W, FRAME_H = 640, 480
FPS = 15
EDGE_FRACTION = 0.18  # 각 변에서 그라디언트 띠가 차지하는 화면 비율
STALE_AFTER = 1.0     # 감지 스레드 갱신이 이 시간(초) 이상 끊기면 오버레이를 끔

MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/1/face_landmarker.task"
)
MODEL_PATH = os.path.join(os.path.expanduser("~/.cache/blink_reminder"), "face_landmarker.task")

# mediapipe/TFLite 가 import 시 쏟아내는 로그를 줄인다 (import 전에 설정해야 함)
os.environ.setdefault("GLOG_minloglevel", "2")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")


# ════════════════════════════════════ 감지 ════════════════════════════════════
class BlinkTracker:
    """eyeBlink 점수에 히스테리시스를 적용해 깜빡임을 세고 '마지막 깜빡임' 타이머를 관리한다.

    - score > close_thresh  → 감김
    - 감김 상태에서 score < open_thresh → 뜸 = 깜빡임 1회
    - 얼굴이 안 보이거나(score=None) 눈이 계속 감겨 있으면 타이머를 계속 리셋해서
      오버레이가 뜨지 않게 한다.
    카메라 스레드가 update()를, UI 스레드가 snapshot()을 호출한다.
    """

    def __init__(self, close_thresh: float, open_thresh: float):
        if open_thresh >= close_thresh:
            raise ValueError("open_thresh 는 close_thresh 보다 작아야 합니다")
        self.close_thresh = close_thresh
        self.open_thresh = open_thresh
        self._lock = threading.Lock()
        self._blink_times: collections.deque[float] = collections.deque()
        self.total_blinks = 0
        self.reset()

    def reset(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        with self._lock:
            self.closed = False
            self.face_visible = False
            self.last_score: float | None = None
            self.last_blink = now      # 타이머 기준 시각
            self.last_update = now     # 마지막 update() 시각

    def update(self, score: float | None, now: float | None = None) -> bool:
        """score: eyeBlinkLeft/Right 평균 (얼굴이 없으면 None). 깜빡임이 셈해지면 True."""
        now = time.monotonic() if now is None else now
        blinked = False
        with self._lock:
            self.last_update = now
            self.last_score = score
            self.face_visible = score is not None
            if score is None:
                self.closed = False          # 얼굴이 사라지면 상태 초기화 (유령 깜빡임 방지)
                self.last_blink = now        # 타이머 리셋
            else:
                if not self.closed and score > self.close_thresh:
                    self.closed = True
                elif self.closed and score < self.open_thresh:
                    self.closed = False
                    blinked = True
                    self.total_blinks += 1
                    self._blink_times.append(now)
                if self.closed or blinked:
                    self.last_blink = now    # 감겨 있는 동안에는 타이머가 흐르지 않음
            cutoff = now - 60.0
            while self._blink_times and self._blink_times[0] < cutoff:
                self._blink_times.popleft()
        return blinked

    def blinks_last_minute(self, now: float | None = None) -> int:
        now = time.monotonic() if now is None else now
        with self._lock:
            return sum(1 for t in self._blink_times if t >= now - 60.0)

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "closed": self.closed,
                "face_visible": self.face_visible,
                "last_score": self.last_score,
                "last_blink": self.last_blink,
                "last_update": self.last_update,
                "total_blinks": self.total_blinks,
            }


def overlay_target_alpha(snap: dict, now: float, limit: float, ramp: float, max_alpha: float) -> float:
    """tracker 스냅샷으로부터 오버레이가 지금 가져야 할 목표 alpha 를 계산한다."""
    if not snap["face_visible"] or snap["closed"]:
        return 0.0
    if now - snap["last_update"] > STALE_AFTER:   # 카메라/감지 스레드가 멈춘 경우
        return 0.0
    since = now - snap["last_blink"]
    if since <= limit:
        return 0.0
    if ramp <= 0:
        return max_alpha
    return max_alpha * min(1.0, (since - limit) / ramp)


def ensure_model(path: str = MODEL_PATH) -> str:
    """face_landmarker.task 가 없으면 다운로드한다 (첫 실행 때 1회)."""
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        return path
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    print(f"[model] 다운로드: {MODEL_URL}\n        → {path}", flush=True)
    tmp = path + ".part"

    last = [-1]

    def hook(blocks: int, block_size: int, total: int) -> None:
        if total <= 0:
            return
        pct = min(100, blocks * block_size * 100 // total)
        if sys.stdout.isatty():
            print(f"\r[model] {pct:3d}%", end="", flush=True)
        elif pct // 10 != last[0]:            # 파이프/로그일 때는 10% 단위로만
            last[0] = pct // 10
            print(f"[model] {pct:3d}%", flush=True)

    try:
        urllib.request.urlretrieve(MODEL_URL, tmp, hook)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    print("\r[model] 다운로드 완료", flush=True)
    return path


class FaceBlinkScorer:
    """MediaPipe Tasks FaceLandmarker (VIDEO 모드, blendshapes 출력) 래퍼."""

    def __init__(self, model_path: str):
        import mediapipe as mp
        from mediapipe.tasks import python as mp_tasks
        from mediapipe.tasks.python import vision

        self._mp = mp
        options = vision.FaceLandmarkerOptions(
            base_options=mp_tasks.BaseOptions(model_asset_path=model_path),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            output_face_blendshapes=True,
            output_facial_transformation_matrixes=False,
        )
        self._landmarker = vision.FaceLandmarker.create_from_options(options)
        self._last_ts = -1

    def score(self, rgb, ts_ms: int | None = None) -> tuple[float, float] | None:
        """RGB uint8 프레임 → (eyeBlinkLeft, eyeBlinkRight). 얼굴이 없으면 None."""
        if ts_ms is None:
            ts_ms = int(time.monotonic() * 1000)
        ts_ms = max(int(ts_ms), self._last_ts + 1)   # VIDEO 모드는 단조 증가 타임스탬프 필수
        self._last_ts = ts_ms
        image = self._mp.Image(image_format=self._mp.ImageFormat.SRGB, data=rgb)
        result = self._landmarker.detect_for_video(image, ts_ms)
        if not result.face_blendshapes:
            return None
        cats = {c.category_name: c.score for c in result.face_blendshapes[0]}
        return cats.get("eyeBlinkLeft", 0.0), cats.get("eyeBlinkRight", 0.0)

    def close(self) -> None:
        self._landmarker.close()


def open_camera(index: int, width: int = FRAME_W, height: int = FRAME_H, fps: int = FPS):
    """VideoCapture 를 연다. 반드시 메인 스레드에서 호출할 것
    (macOS 는 카메라 권한 프롬프트가 메인 스레드에서만 정상 동작한다)."""
    import cv2

    backend = cv2.CAP_AVFOUNDATION if sys.platform == "darwin" else cv2.CAP_ANY
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        raise RuntimeError(
            f"카메라 {index} 를 열 수 없습니다. --camera 로 다른 인덱스를 지정하거나 "
            "시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 터미널 앱 권한을 확인하세요."
        )
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    # 워밍업: 권한 프롬프트 직후 몇 프레임은 실패할 수 있다
    for _ in range(30):
        ok, _frame = cap.read()
        if ok:
            break
        time.sleep(0.1)
    else:
        print("[camera] 경고: 프레임을 아직 못 받았습니다 (권한 대기 중?). 계속 시도합니다.", file=sys.stderr)
    return cap


class CameraWorker(threading.Thread):
    """백그라운드에서 카메라 프레임을 읽어 점수를 내고 tracker 를 갱신한다."""

    def __init__(self, cap, scorer: FaceBlinkScorer, tracker: BlinkTracker, fps: int, debug: bool):
        super().__init__(name="camera", daemon=True)
        self.cap = cap
        self.scorer = scorer
        self.tracker = tracker
        self.interval = 1.0 / max(1, fps)
        self.debug = debug
        self._stop_event = threading.Event()

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        import cv2

        while not self._stop_event.is_set():
            t0 = time.monotonic()
            ok, frame = self.cap.read()
            if not ok:
                self.tracker.update(None)
                self._stop_event.wait(0.2)
                continue
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            try:
                scores = self.scorer.score(rgb, int(t0 * 1000))
            except Exception as e:          # 감지 실패가 앱 전체를 죽이지 않게
                print(f"[detect] 오류: {e}", file=sys.stderr)
                scores = None
            avg = None if scores is None else (scores[0] + scores[1]) / 2.0
            blinked = self.tracker.update(avg)
            if self.debug:
                now = time.monotonic()
                snap = self.tracker.snapshot()
                if scores is None:
                    line = "L=----  R=----  avg=----  face=0"
                else:
                    line = f"L={scores[0]:.2f}  R={scores[1]:.2f}  avg={avg:.2f}  face=1"
                print(
                    f"[debug] {line}  closed={int(snap['closed'])}  "
                    f"since_blink={now - snap['last_blink']:4.1f}s  "
                    f"blinks/min={self.tracker.blinks_last_minute(now):2d}"
                    + ("  ← BLINK" if blinked else ""),
                    flush=True,
                )
            remaining = self.interval - (time.monotonic() - t0)
            if remaining > 0:
                self._stop_event.wait(remaining)


# ═════════════════════════════ macOS 오버레이 + 메뉴바 ═════════════════════════════
def run_app(args: argparse.Namespace, scorer: FaceBlinkScorer, tracker: BlinkTracker) -> None:
    import objc
    from AppKit import (
        NSApplication,
        NSApplicationActivationPolicyAccessory,
        NSApplicationDidChangeScreenParametersNotification,
        NSBackingStoreBuffered,
        NSColor,
        NSGradient,
        NSMenu,
        NSMenuItem,
        NSScreen,
        NSScreenSaverWindowLevel,
        NSStatusBar,
        NSVariableStatusItemLength,
        NSView,
        NSWindow,
        NSWindowCollectionBehaviorCanJoinAllSpaces,
        NSWindowCollectionBehaviorFullScreenAuxiliary,
        NSWindowCollectionBehaviorIgnoresCycle,
        NSWindowCollectionBehaviorStationary,
        NSWindowStyleMaskBorderless,
    )
    from Foundation import (
        NSMakeRect,
        NSNotificationCenter,
        NSObject,
        NSRunLoop,
        NSRunLoopCommonModes,
        NSTimer,
    )

    edge = args.edge

    class EdgeView(NSView):
        """화면 네 변에 검정→투명 그라디언트 띠를 그린다. 강도는 창 alpha 로 조절."""

        def initWithFrame_(self, frame):
            self = objc.super(EdgeView, self).initWithFrame_(frame)
            if self is None:
                return None
            self._gradient = NSGradient.alloc().initWithStartingColor_endingColor_(
                NSColor.blackColor(), NSColor.colorWithCalibratedWhite_alpha_(0.0, 0.0)
            )
            return self

        def isOpaque(self):
            return False

        def drawRect_(self, rect):
            b = self.bounds()
            w, h = b.size.width, b.size.height
            ex, ey = w * edge, h * edge
            g = self._gradient
            g.drawInRect_angle_(NSMakeRect(0, 0, ex, h), 0)          # 왼쪽  (검정 → 투명, →)
            g.drawInRect_angle_(NSMakeRect(w - ex, 0, ex, h), 180)   # 오른쪽 (←)
            g.drawInRect_angle_(NSMakeRect(0, 0, w, ey), 90)         # 아래   (↑)
            g.drawInRect_angle_(NSMakeRect(0, h - ey, w, ey), 270)   # 위     (↓)

    def make_overlay_window(screen):
        frame = screen.frame()
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, NSWindowStyleMaskBorderless, NSBackingStoreBuffered, False
        )
        win.setReleasedWhenClosed_(False)
        win.setOpaque_(False)
        win.setBackgroundColor_(NSColor.clearColor())
        win.setHasShadow_(False)
        win.setIgnoresMouseEvents_(True)                      # 클릭 통과
        win.setLevel_(NSScreenSaverWindowLevel)               # 최상위
        win.setCollectionBehavior_(                           # 모든 Space / 전체화면에서 보임
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorIgnoresCycle
        )
        win.setAlphaValue_(0.0)
        view = EdgeView.alloc().initWithFrame_(NSMakeRect(0, 0, frame.size.width, frame.size.height))
        win.setContentView_(view)
        win.orderFrontRegardless()
        return win

    class AppController(NSObject):
        def init(self):
            self = objc.super(AppController, self).init()
            if self is None:
                return None
            self.windows = []
            self.worker = None
            self.cap = None
            self.paused = False
            self.alpha = 0.0
            self.want_quit = False
            self.last_tick = time.monotonic()
            self.last_menu_refresh = 0.0
            return self

        # ── 설정 ──
        def setup(self):
            self.buildStatusItem()
            self.buildWindows()
            NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
                self, "screensChanged:", NSApplicationDidChangeScreenParametersNotification, None
            )
            self.startCamera()
            timer = NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
                1.0 / 30.0, self, "tick:", None, True
            )
            # CommonModes 에 넣어야 메뉴가 열려 있는 동안에도 타이머가 돈다
            NSRunLoop.currentRunLoop().addTimer_forMode_(timer, NSRunLoopCommonModes)
            self.timer = timer

        def buildStatusItem(self):
            self.status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
            self.status_item.button().setTitle_("👁")
            self.status_item.button().setToolTip_("Blink Reminder")
            menu = NSMenu.alloc().init()
            menu.setAutoenablesItems_(False)
            self.count_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("최근 1분 깜빡임: 0회", None, "")
            self.count_item.setEnabled_(False)
            menu.addItem_(self.count_item)
            self.status_line = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("상태: 시작 중", None, "")
            self.status_line.setEnabled_(False)
            menu.addItem_(self.status_line)
            menu.addItem_(NSMenuItem.separatorItem())
            self.pause_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("일시정지", "togglePause:", "p")
            self.pause_item.setTarget_(self)
            menu.addItem_(self.pause_item)
            quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("종료", "quit:", "q")
            quit_item.setTarget_(self)
            menu.addItem_(quit_item)
            menu.setDelegate_(self)
            self.status_item.setMenu_(menu)

        def buildWindows(self):
            for w in self.windows:
                w.orderOut_(None)
            self.windows = [make_overlay_window(s) for s in NSScreen.screens()]
            for w in self.windows:
                w.setAlphaValue_(self.alpha)

        # ── 카메라 ──
        def startCamera(self):
            try:
                self.cap = open_camera(args.camera, fps=args.fps)   # 메인 스레드에서 연다
            except Exception as e:
                print(f"[camera] {e}", file=sys.stderr)
                self.paused = True
                self.pause_item.setTitle_("재개 (카메라 재시도)")
                self.status_item.button().setAppearsDisabled_(True)
                return
            tracker.reset()
            self.worker = CameraWorker(self.cap, scorer, tracker, args.fps, args.debug)
            self.worker.start()
            self.paused = False
            self.pause_item.setTitle_("일시정지")
            self.status_item.button().setAppearsDisabled_(False)

        def stopCamera(self):
            if self.worker is not None:
                self.worker.stop()
                self.worker.join(timeout=3.0)
                self.worker = None
            if self.cap is not None:
                self.cap.release()                                   # 일시정지 시 카메라 해제
                self.cap = None
            tracker.reset()
            self.paused = True
            self.pause_item.setTitle_("재개")
            self.status_item.button().setAppearsDisabled_(True)

        # ── 액션 ──
        def togglePause_(self, sender):
            if self.paused:
                self.startCamera()
            else:
                self.stopCamera()

        def quit_(self, sender):
            self.timer.invalidate()
            self.stopCamera()
            for w in self.windows:
                w.orderOut_(None)
            try:
                scorer.close()
            except Exception:
                pass
            print(f"[app] 종료. 총 깜빡임 {tracker.total_blinks}회", flush=True)
            NSApplication.sharedApplication().terminate_(None)

        def screensChanged_(self, note):
            self.buildWindows()

        def menuNeedsUpdate_(self, menu):
            self.refreshMenu()

        def refreshMenu(self):
            now = time.monotonic()
            self.count_item.setTitle_(f"최근 1분 깜빡임: {tracker.blinks_last_minute(now)}회")
            snap = tracker.snapshot()
            if self.paused:
                status = "일시정지 (카메라 꺼짐)"
            elif now - snap["last_update"] > STALE_AFTER:
                status = "카메라 프레임 없음"
            elif not snap["face_visible"]:
                status = "얼굴 없음"
            elif snap["closed"]:
                status = "눈 감김"
            else:
                status = f"마지막 깜빡임 {now - snap['last_blink']:.1f}초 전"
            self.status_line.setTitle_(f"상태: {status}")

        # ── 30Hz 틱: 오버레이 alpha 갱신 ──
        def tick_(self, timer):
            if self.want_quit:
                self.quit_(None)
                return
            now = time.monotonic()
            dt = now - self.last_tick
            self.last_tick = now

            target = 0.0
            if not self.paused:
                target = overlay_target_alpha(tracker.snapshot(), now, args.limit, args.ramp, args.max_alpha)
            if target >= self.alpha:
                alpha = target                                        # 올라갈 때는 RAMP 가 속도를 정함
            else:
                step = args.max_alpha * dt / max(args.fade_out, 1e-3)  # 내려갈 때는 FADE_OUT 안에 0 으로
                alpha = max(target, self.alpha - step)
            if alpha != self.alpha:
                self.alpha = alpha
                for w in self.windows:
                    w.setAlphaValue_(alpha)

            if now - self.last_menu_refresh > 1.0:
                self.last_menu_refresh = now
                self.refreshMenu()

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)   # Dock 아이콘 없음
    controller = AppController.alloc().init()
    controller.setup()

    # Ctrl-C: 핸들러는 30Hz 타이머 콜백(파이썬 코드) 중에 실행되고, 다음 tick 에서 정리 후 종료
    def on_sigint(signum, frame):
        controller.want_quit = True

    signal.signal(signal.SIGINT, on_sigint)
    signal.signal(signal.SIGTERM, on_sigint)
    print("[app] 메뉴바의 👁 아이콘에서 일시정지/종료할 수 있습니다. (Ctrl-C 로도 종료)", flush=True)
    app.run()


# ═══════════════════════════ 터미널 전용 모드 (오버레이 없음) ═══════════════════════════
def run_headless(args: argparse.Namespace, scorer: FaceBlinkScorer, tracker: BlinkTracker) -> None:
    cap = open_camera(args.camera, fps=args.fps)      # 메인 스레드
    worker = CameraWorker(cap, scorer, tracker, args.fps, args.debug)
    worker.start()
    print("[headless] 오버레이 없이 감지만 합니다. Ctrl-C 로 종료.", flush=True)
    try:
        while True:
            time.sleep(1.0)
            if not args.debug:
                now = time.monotonic()
                snap = tracker.snapshot()
                alpha = overlay_target_alpha(snap, now, args.limit, args.ramp, args.max_alpha)
                print(
                    f"[headless] face={int(snap['face_visible'])} closed={int(snap['closed'])} "
                    f"since_blink={now - snap['last_blink']:4.1f}s overlay_alpha={alpha:.2f} "
                    f"blinks/min={tracker.blinks_last_minute(now)}",
                    flush=True,
                )
    except KeyboardInterrupt:
        pass
    finally:
        worker.stop()
        worker.join(timeout=3.0)
        cap.release()
        scorer.close()
        print(f"\n[headless] 종료. 총 깜빡임 {tracker.total_blinks}회", flush=True)


# ════════════════════════════════════ 진입점 ════════════════════════════════════
def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="웹캠으로 깜빡임을 감지해, 오래 안 깜빡이면 화면 가장자리를 어둡게 하는 macOS 메뉴바 앱",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--limit", type=float, default=LIMIT, help="마지막 깜빡임 후 어두워지기 시작하는 시간(초)")
    p.add_argument("--ramp", type=float, default=RAMP, help="0 → 최대 불투명도까지 걸리는 시간(초)")
    p.add_argument("--max-alpha", type=float, default=MAX_ALPHA, help="오버레이 최대 불투명도 (0~1)")
    p.add_argument("--fade-out", type=float, default=FADE_OUT, help="깜빡였을 때 사라지는 시간(초)")
    p.add_argument("--close-thresh", type=float, default=CLOSE_THRESH, help="eyeBlink 평균이 이 값 초과면 감김")
    p.add_argument("--open-thresh", type=float, default=OPEN_THRESH, help="감김 상태에서 이 값 미만이면 뜸")
    p.add_argument("--camera", type=int, default=CAMERA_INDEX, help="카메라 인덱스")
    p.add_argument("--fps", type=int, default=FPS, help="감지 프레임레이트")
    p.add_argument("--edge", type=float, default=EDGE_FRACTION, help="가장자리 그라디언트 띠 폭 (화면 비율)")
    p.add_argument("--model", default=MODEL_PATH, help="face_landmarker.task 경로 (없으면 자동 다운로드)")
    p.add_argument("--debug", action="store_true", help="프레임마다 blink 점수를 터미널에 출력")
    p.add_argument("--headless", action="store_true", help="오버레이/메뉴바 없이 터미널에서 감지만 (튜닝용)")
    args = p.parse_args(argv)
    if args.open_thresh >= args.close_thresh:
        p.error("--open-thresh 는 --close-thresh 보다 작아야 합니다")
    if not 0.0 < args.max_alpha <= 1.0:
        p.error("--max-alpha 는 0 초과 1 이하여야 합니다")
    return args


def main(argv=None) -> int:
    args = parse_args(argv)
    model_path = ensure_model(args.model)
    tracker = BlinkTracker(args.close_thresh, args.open_thresh)
    scorer = FaceBlinkScorer(model_path)
    print(
        f"[app] LIMIT={args.limit}s RAMP={args.ramp}s MAX_ALPHA={args.max_alpha} "
        f"close>{args.close_thresh} open<{args.open_thresh} camera={args.camera}",
        flush=True,
    )
    try:
        if args.headless or sys.platform != "darwin":
            if sys.platform != "darwin" and not args.headless:
                print("[app] macOS 가 아니므로 --headless 모드로 실행합니다.", file=sys.stderr)
            run_headless(args, scorer, tracker)
        else:
            run_app(args, scorer, tracker)
    except RuntimeError as e:            # 카메라를 못 여는 경우 등: 한 줄로 알리고 종료
        print(f"[app] 오류: {e}", file=sys.stderr)
        scorer.close()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

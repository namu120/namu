import AVFoundation
import Vision
import BlinkCore

/// 웹캠 프레임을 받아 Apple Vision 으로 눈 랜드마크를 찾고 좌/우 EAR 을 콜백으로 넘긴다.
/// 영상은 메모리에서만 처리되며 어디에도 저장·전송되지 않는다.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Frame {
        var timestamp: TimeInterval
        var faceFound: Bool
        var leftEAR: Double?
        var rightEAR: Double?
    }

    struct Device: Identifiable, Equatable {
        var id: String
        var name: String
    }

    enum CameraError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "사용할 수 있는 카메라가 없습니다."
            case .cannotAddInput: return "카메라 입력을 추가할 수 없습니다."
            case .cannotAddOutput: return "비디오 출력을 추가할 수 없습니다."
            }
        }
    }

    /// 카메라 큐에서 호출된다.
    var onFrame: (@Sendable (Frame) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "blink.camera", qos: .userInitiated)
    private var minInterval: TimeInterval = 1.0 / 15.0
    private var lastProcessed: TimeInterval = 0
    private(set) var isRunning = false

    // MARK: 권한 / 장치 목록

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    static func availableCameras() -> [Device] {
        availableDevices().map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: 시작 / 정지

    func start(deviceID: String?, frameRate: Int) throws {
        let devices = Self.availableDevices()
        guard let device = devices.first(where: { $0.uniqueID == deviceID })
                ?? AVCaptureDevice.default(for: .video)
                ?? devices.first else {
            throw CameraError.noCamera
        }
        minInterval = 1.0 / Double(max(frameRate, 1))

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraError.cannotAddOutput
            }
            session.addOutput(output)
        }
        session.commitConfiguration()

        // 카메라 자체 프레임레이트도 낮춰 CPU 를 아낀다 (지원하지 않는 포맷이면 무시)
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
           Double(frameRate) >= range.minFrameRate, Double(frameRate) <= range.maxFrameRate,
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            device.unlockForConfiguration()
        }

        isRunning = true
        queue.async { [session] in session.startRunning() }   // startRunning 은 블로킹이라 메인에서 부르지 않는다
    }

    func stop() {
        isRunning = false
        queue.async { [session] in
            session.stopRunning()                               // 카메라 표시등도 꺼진다
        }
    }

    // MARK: 프레임 처리

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProcessed >= minInterval * 0.9 else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            onFrame?(Frame(timestamp: now, faceFound: false, leftEAR: nil, rightEAR: nil))
            return
        }
        // 가장 큰 얼굴 하나만 본다
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks else {
            onFrame?(Frame(timestamp: now, faceFound: false, leftEAR: nil, rightEAR: nil))
            return
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let left = landmarks.leftEye.flatMap { Self.ear($0, imageSize: size) }
        let right = landmarks.rightEye.flatMap { Self.ear($0, imageSize: size) }
        onFrame?(Frame(timestamp: now, faceFound: true, leftEAR: left, rightEAR: right))
    }

    private static func ear(_ region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> Double? {
        let pts = region.pointsInImage(imageSize: imageSize).map { EyeMetrics.Point(Double($0.x), Double($0.y)) }
        return EyeMetrics.aspectRatio(pts)
    }
}

import Foundation
@preconcurrency import AVFoundation
import Vision
import AppKit
import CoreML

enum VisionExpression: String {
    case smile, surprised, sleepy

    var eventKind: String { "see_\(rawValue)" }

    var summary: String {
        switch self {
        case .smile: return "你看见主人在笑"
        case .surprised: return "你看见主人好像有点惊讶"
        case .sleepy: return "你看见主人眯着眼睛,像是有点累"
        }
    }
}

enum VisionGesture: String {
    case wave, openPalm, thumbsUp, ok, pointing

    var eventKind: String { "gesture_\(rawValue)" }

    var summary: String {
        switch self {
        case .wave: return "你看见主人向你挥手"
        case .openPalm: return "你看见主人把手掌伸给你看"
        case .thumbsUp: return "你看见主人竖起了大拇指"
        case .ok: return "你看见主人比了一个 OK 手势"
        case .pointing: return "你看见主人伸出手指指了指"
        }
    }
}

struct VisionObjectObservation: Hashable {
    let label: String
    let confidence: Float
    let center: CGPoint?
    let area: CGFloat?

    init(label: String, confidence: Float, center: CGPoint? = nil, area: CGFloat? = nil) {
        self.label = label
        self.confidence = confidence
        self.center = center
        self.area = area
    }

    var summary: String {
        "你看见附近有\(VisionObjectObservation.localizedLabel(label))"
    }

    static func localizedLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "person": return "人"
        case "cell phone", "phone", "mobile phone": return "手机"
        case "cup", "mug": return "杯子"
        case "book": return "书"
        case "keyboard": return "键盘"
        case "mouse": return "鼠标"
        case "laptop": return "笔记本电脑"
        case "bottle": return "瓶子"
        case "dog": return "狗"
        case "cat": return "猫"
        default: return label
        }
    }
}

enum VideoUnderstandingEvent: String {
    case personApproached, personMovedAway, personMovedLeft, personMovedRight
    case handReachedTowardCamera
    case objectAppeared, objectDisappeared, objectMoved

    var eventKind: String { "video_\(rawValue)" }

    func summary(label: String? = nil) -> String {
        switch self {
        case .personApproached: return "你看见主人好像靠近了一点"
        case .personMovedAway: return "你看见主人好像离远了一点"
        case .personMovedLeft: return "你看见主人往左边动了动"
        case .personMovedRight: return "你看见主人往右边动了动"
        case .handReachedTowardCamera: return "你看见主人的手靠近了你"
        case .objectAppeared: return "你看见\(label ?? "一个东西")出现在附近"
        case .objectDisappeared: return "你看见\(label ?? "一个东西")不见了"
        case .objectMoved: return "你看见\(label ?? "一个东西")被挪动了"
        }
    }
}

/// 用户主动开启摄像头时的真实结果(用于给出正确反馈,而非假装成功)。
enum VisionStartOutcome {
    case started     // 已授权且会话起来了
    case denied      // 系统权限被拒/受限
    case noDevice    // 找不到摄像头
    case failed      // 会话配置失败
}

/// Optional camera sense. PRIVACY: frames are analyzed locally and discarded
/// immediately — only boolean events ("主人回来了" / "主人在笑") ever leave this
/// class. No image is stored, uploaded, or shown. Default OFF; toggled by owner.
@MainActor
final class VisionSensor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "gugu.vision")
    private let objectRecognizer = LocalObjectRecognizer()
    private let frameGate = VisionFrameGate()
    private var running = false

    // debounced state
    private var facePresent = false
    private var lastExpression: [VisionExpression: Date] = [:]
    private var lastGesture: [VisionGesture: Date] = [:]
    private var lastObject: [String: Date] = [:]
    private var lastPresenceChange = Date.distantPast
    private var gestureCandidate: VisionGesture?
    private var gestureCandidateCount = 0
    private var lastOpenPalmCenter: CGPoint?
    private var lastObjectLabels: [String: Int] = [:]
    private let videoTracker = VideoUnderstandingTracker()

    private(set) var available = false
    var onPresence: ((Bool) -> Void)?     // true = appeared, false = left
    var onSmile: (() -> Void)?
    var onExpression: ((VisionExpression) -> Void)?
    var onGesture: ((VisionGesture) -> Void)?
    var onObject: ((VisionObjectObservation) -> Void)?
    var onVideoEvent: ((VideoUnderstandingEvent, String?) -> Void)?

    var objectRecognitionAvailable: Bool {
        objectRecognizer.available
    }

    /// Whether the user has authorized & enabled the camera sense.
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.camera.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.camera.enabled")
              if newValue { startIfPossible() } else { stop() } }
    }

    func startIfPossible() {
        guard enabled, !running else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard granted, self?.enabled == true else { return }
                    self?.configureAndStart()
                }
            }
        default:
            Log.info("vision", "摄像头未授权(系统设置里可开启)")
        }
    }

    /// 用户主动点"睁眼"时的入口:开启并把**真实结果**回调出去——
    /// 授权通过且会话起来了才报 .started,被拒报 .denied,没设备报 .noDevice。
    /// 这样菜单就不会在权限被拒时还假装"睁开眼睛看了看你"。
    func requestEnable(_ completion: @escaping (VisionStartOutcome) -> Void) {
        UserDefaults.standard.set(true, forKey: "gugu.camera.enabled")
        guard !running else { completion(.started); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(announce: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else { completion(.denied); return }
                    guard self.enabled else { return }
                    self.configureAndStart(announce: completion)
                }
            }
        default:   // .denied / .restricted
            completion(.denied)
        }
    }

    private func configureAndStart(announce: ((VisionStartOutcome) -> Void)? = nil) {
        guard enabled, !running else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.info("vision", "没有可用摄像头")
            announce?(.noDevice)
            return
        }
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true

        let generation = frameGate.start()
        running = true
        available = false

        queue.async { [weak self, session, input, output, generation] in
            session.beginConfiguration()
            session.sessionPreset = .low   // we only need low-res for face presence
            for oldOutput in session.outputs {
                if let videoOutput = oldOutput as? AVCaptureVideoDataOutput {
                    videoOutput.setSampleBufferDelegate(nil, queue: nil)
                }
                session.removeOutput(oldOutput)
            }
            for oldInput in session.inputs {
                session.removeInput(oldInput)
            }

            let configured = session.canAddInput(input) && session.canAddOutput(output)
            if configured {
                session.addInput(input)
                session.addOutput(output)
            }
            session.commitConfiguration()
            if configured {
                session.startRunning()
            }

            Task { @MainActor in
                guard let self else { return }
                guard configured else {
                    if self.frameGate.deactivateIfCurrent(generation) {
                        self.running = false
                        self.available = false
                    }
                    Log.info("vision", "摄像头会话配置失败")
                    announce?(.failed)
                    return
                }
                guard self.enabled, self.frameGate.accepts(generation) else { return }
                self.running = true
                self.available = true
                Log.info("vision", "咕咕睁开了眼睛(只在本机看,看完即忘)")
                announce?(.started)
            }
        }
    }

    func stop() {
        guard running || available || frameGate.isAccepting else { return }
        frameGate.stop()
        running = false
        available = false
        resetTransientVisionState()
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
            // drop any inputs so a future enable reconfigures cleanly
            session.beginConfiguration()
            for output in session.outputs {
                if let videoOutput = output as? AVCaptureVideoDataOutput {
                    videoOutput.setSampleBufferDelegate(nil, queue: nil)
                }
                session.removeOutput(output)
            }
            for input in session.inputs {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
        Log.info("vision", "咕咕闭上了眼睛")
    }

    // MARK: - Frame analysis (local only)

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Full-speed local recognition: AVCapture drops late frames so inference never backlogs.
        guard let generation = frameGate.currentGenerationIfAccepting() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        var requests: [VNRequest] = [faceRequest, handRequest]
        let includesObjectRecognition = VisionPerformancePolicy.allowsObjectRecognition
        let objectRequest = includesObjectRecognition ? objectRecognizer.makeRecognitionRequest() : nil
        if let objectRequest {
            requests.append(objectRequest)
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let didPerform: Bool
        do {
            try handler.perform(requests)
            didPerform = true
        } catch {
            didPerform = false
        }
        let faces = didPerform ? (faceRequest.results ?? []) : []
        let handObservations = didPerform ? (handRequest.results ?? []) : []
        let faceSignals = VisionSensor.faceSignals(from: faces.first)
        let handSignals = VisionSensor.handSignals(from: handObservations)
        let objects = didPerform ? objectRecognizer.results(from: objectRequest) : []
        if let stats = frameGate.recordFrame(objectFrame: objectRequest != nil) {
            Log.info("vision", stats)
        }
        // pixelBuffer goes out of scope here — nothing retained
        Task { @MainActor in
            guard self.frameGate.accepts(generation) else { return }
            self.handle(face: faceSignals, hand: handSignals, objects: objects)
        }
    }

    private func handle(face: FaceSignals, hand: HandSignals, objects: [VisionObjectObservation]) {
        let now = Date()

        if face.present != facePresent, now.timeIntervalSince(lastPresenceChange) > 4 {
            facePresent = face.present
            lastPresenceChange = now
            onPresence?(face.present)
        }

        for expression in face.expressions {
            guard now.timeIntervalSince(lastExpression[expression] ?? .distantPast) > 30 else { continue }
            lastExpression[expression] = now
            if expression == .smile { onSmile?() }
            onExpression?(expression)
        }

        if let gesture = stableGesture(from: hand, now: now),
           now.timeIntervalSince(lastGesture[gesture] ?? .distantPast) > 12 {
            lastGesture[gesture] = now
            onGesture?(gesture)
        }

        for object in stableObjects(from: objects, now: now) {
            onObject?(object)
        }
        for event in videoTracker.ingest(face: face, hand: hand, objects: objects, now: now) {
            onVideoEvent?(event.kind, event.label)
        }
    }

    private func resetTransientVisionState() {
        facePresent = false
        lastPresenceChange = .distantPast
        gestureCandidate = nil
        gestureCandidateCount = 0
        lastOpenPalmCenter = nil
        lastObjectLabels.removeAll()
        videoTracker.reset()
    }

    private func stableGesture(from hand: HandSignals, now: Date) -> VisionGesture? {
        guard let gesture = hand.gesture else {
            gestureCandidate = nil
            gestureCandidateCount = 0
            lastOpenPalmCenter = nil
            return nil
        }

        if gesture == .openPalm, let center = hand.center {
            defer { lastOpenPalmCenter = center }
            if let lastOpenPalmCenter, abs(center.x - lastOpenPalmCenter.x) > 0.16 {
                gestureCandidate = nil
                gestureCandidateCount = 0
                return .wave
            }
        }

        if gestureCandidate == gesture {
            gestureCandidateCount += 1
        } else {
            gestureCandidate = gesture
            gestureCandidateCount = 1
        }
        return gestureCandidateCount >= 2 ? gesture : nil
    }

    private func stableObjects(from objects: [VisionObjectObservation], now: Date) -> [VisionObjectObservation] {
        var emitted: [VisionObjectObservation] = []
        var currentLabels = Set<String>()
        for object in objects where object.confidence >= 0.58 {
            let label = object.label.lowercased()
            currentLabels.insert(label)
            lastObjectLabels[label, default: 0] += 1
            guard lastObjectLabels[label, default: 0] >= 2,
                  now.timeIntervalSince(lastObject[label] ?? .distantPast) > 90 else { continue }
            lastObject[label] = now
            emitted.append(object)
        }
        for label in lastObjectLabels.keys where !currentLabels.contains(label) {
            lastObjectLabels[label] = 0
        }
        return emitted
    }

    nonisolated fileprivate struct FaceSignals {
        var present: Bool
        var expressions: [VisionExpression]
        var center: CGPoint?
        var area: CGFloat?
    }

    nonisolated fileprivate struct HandSignals {
        var gesture: VisionGesture?
        var center: CGPoint?
        var area: CGFloat?
    }

    nonisolated private static func faceSignals(from face: VNFaceObservation?) -> FaceSignals {
        guard let face else { return FaceSignals(present: false, expressions: []) }
        var expressions: [VisionExpression] = []
        let landmarks = face.landmarks
        if let mouth = landmarks?.outerLips,
           let metrics = landmarkMetrics(mouth.normalizedPoints) {
            if metrics.height > 0, metrics.width / metrics.height > 3.2 {
                expressions.append(.smile)
            } else if metrics.width > 0, metrics.height / metrics.width > 0.34 {
                expressions.append(.surprised)
            }
        }
        if let leftEye = landmarks?.leftEye,
           let rightEye = landmarks?.rightEye,
           let left = landmarkMetrics(leftEye.normalizedPoints),
           let right = landmarkMetrics(rightEye.normalizedPoints),
           left.width > 0,
           right.width > 0,
           left.height / left.width < 0.16,
           right.height / right.width < 0.16 {
            expressions.append(.sleepy)
        }
        return FaceSignals(present: true,
                           expressions: expressions,
                           center: CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY),
                           area: face.boundingBox.width * face.boundingBox.height)
    }

    nonisolated private static func landmarkMetrics(_ points: [CGPoint]) -> (width: CGFloat, height: CGFloat)? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return (maxX - minX, maxY - minY)
    }

    nonisolated private static func handSignals(from observations: [VNHumanHandPoseObservation]) -> HandSignals {
        guard let observation = observations.first,
              let points = try? observation.recognizedPoints(.all) else {
            return HandSignals()
        }
        let minConfidence: VNConfidence = 0.35
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let recognized = points[name], recognized.confidence >= minConfidence else { return nil }
            return recognized.location
        }
        guard let wrist = point(.wrist),
              let indexTip = point(.indexTip),
              let middleTip = point(.middleTip),
              let ringTip = point(.ringTip),
              let littleTip = point(.littleTip) else {
            return HandSignals()
        }

        let fingertips = [indexTip, middleTip, ringTip, littleTip]
        let center = CGPoint(x: fingertips.map(\.x).reduce(0, +) / CGFloat(fingertips.count),
                             y: fingertips.map(\.y).reduce(0, +) / CGFloat(fingertips.count))
        let allPoints = points.values.filter { $0.confidence >= minConfidence }.map(\.location)
        let handArea = boundingArea(allPoints)
        let palmSpan = max(0.05, hypot(indexTip.x - littleTip.x, indexTip.y - littleTip.y))
        let indexExtended = distance(indexTip, wrist) > palmSpan * 1.35
        let middleExtended = distance(middleTip, wrist) > palmSpan * 1.25
        let ringExtended = distance(ringTip, wrist) > palmSpan * 1.15
        let littleExtended = distance(littleTip, wrist) > palmSpan * 1.05

        if let thumbTip = point(.thumbTip), distance(thumbTip, indexTip) < palmSpan * 0.42 {
            return HandSignals(gesture: .ok, center: center, area: handArea)
        }
        if indexExtended && middleExtended && ringExtended && littleExtended {
            return HandSignals(gesture: .openPalm, center: center, area: handArea)
        }
        if indexExtended && !middleExtended && !ringExtended && !littleExtended {
            return HandSignals(gesture: .pointing, center: center, area: handArea)
        }
        if let thumbTip = point(.thumbTip),
           thumbTip.y > max(indexTip.y, middleTip.y, ringTip.y, littleTip.y) + 0.08 {
            return HandSignals(gesture: .thumbsUp, center: center, area: handArea)
        }
        return HandSignals(center: center, area: handArea)
    }

    nonisolated private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    nonisolated private static func boundingArea(_ points: [CGPoint]) -> CGFloat? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }
}

private final class VisionFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var accepting = false
    private var frameCount = 0
    private var objectFrameCount = 0
    private var statsStartedAt = Date()

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    func start() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        accepting = true
        frameCount = 0
        objectFrameCount = 0
        statsStartedAt = Date()
        return generation
    }

    func stop() {
        lock.lock()
        generation += 1
        accepting = false
        lock.unlock()
    }

    func deactivateIfCurrent(_ expectedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        accepting = false
        return true
    }

    func currentGenerationIfAccepting() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return accepting ? generation : nil
    }

    func accepts(_ expectedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting && generation == expectedGeneration
    }

    func recordFrame(objectFrame: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        frameCount += 1
        if objectFrame { objectFrameCount += 1 }
        let elapsed = Date().timeIntervalSince(statsStartedAt)
        guard elapsed >= 30 else { return nil }
        let fps = Double(frameCount) / elapsed
        let objectFPS = Double(objectFrameCount) / elapsed
        frameCount = 0
        objectFrameCount = 0
        statsStartedAt = Date()
        return String(format: "本机视频识别 %.1f fps,物品 %.1f fps", fps, objectFPS)
    }
}

private enum VisionPerformancePolicy {
    static var allowsObjectRecognition: Bool {
        guard UserDefaults.standard.object(forKey: "gugu.vision.objects.enabled") == nil
                || UserDefaults.standard.bool(forKey: "gugu.vision.objects.enabled") else {
            return false
        }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        switch info.thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }
}

@MainActor
enum VisionDebugSelfTest {
    static func videoTrackerResetsStaleTracks() -> Bool {
        let tracker = VideoUnderstandingTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let faceA = VisionSensor.FaceSignals(present: true,
                                             expressions: [],
                                             center: CGPoint(x: 0.20, y: 0.50),
                                             area: 0.08)
        let faceMissing = VisionSensor.FaceSignals(present: false, expressions: [])
        let faceB = VisionSensor.FaceSignals(present: true,
                                             expressions: [],
                                             center: CGPoint(x: 0.70, y: 0.50),
                                             area: 0.18)
        let emptyHand = VisionSensor.HandSignals()
        _ = tracker.ingest(face: faceA, hand: emptyHand, objects: [], now: start)
        _ = tracker.ingest(face: faceMissing, hand: emptyHand, objects: [], now: start.addingTimeInterval(0.4))
        let events = tracker.ingest(face: faceB, hand: emptyHand, objects: [], now: start.addingTimeInterval(1.1))
        return events.isEmpty
    }

    static func objectAppearedRequiresStableFrames() -> Bool {
        let tracker = VideoUnderstandingTracker()
        let start = Date(timeIntervalSince1970: 2_000)
        let emptyFace = VisionSensor.FaceSignals(present: false, expressions: [])
        let emptyHand = VisionSensor.HandSignals()
        let cup = VisionObjectObservation(label: "cup",
                                          confidence: 0.72,
                                          center: CGPoint(x: 0.30, y: 0.40),
                                          area: 0.05)
        let first = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [cup], now: start)
        let second = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [cup], now: start.addingTimeInterval(0.2))
        return first.isEmpty && second.contains { $0.kind == .objectAppeared && $0.label == "杯子" }
    }

    static func objectReappearanceDoesNotBecomeMovement() -> Bool {
        let tracker = VideoUnderstandingTracker()
        let start = Date(timeIntervalSince1970: 3_000)
        let emptyFace = VisionSensor.FaceSignals(present: false, expressions: [])
        let emptyHand = VisionSensor.HandSignals()
        let leftCup = VisionObjectObservation(label: "cup",
                                              confidence: 0.76,
                                              center: CGPoint(x: 0.20, y: 0.40),
                                              area: 0.05)
        let rightCup = VisionObjectObservation(label: "cup",
                                               confidence: 0.77,
                                               center: CGPoint(x: 0.82, y: 0.42),
                                               area: 0.05)
        _ = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [leftCup], now: start)
        _ = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [leftCup], now: start.addingTimeInterval(0.2))
        _ = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [], now: start.addingTimeInterval(2.4))
        let firstReturn = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [rightCup], now: start.addingTimeInterval(2.7))
        let secondReturn = tracker.ingest(face: emptyFace, hand: emptyHand, objects: [rightCup], now: start.addingTimeInterval(2.9))
        return !firstReturn.contains { $0.kind == .objectMoved }
            && !secondReturn.contains { $0.kind == .objectMoved }
    }

    static func frameGateRejectsOldGenerations() -> Bool {
        let gate = VisionFrameGate()
        let first = gate.start()
        guard gate.accepts(first), gate.currentGenerationIfAccepting() == first else { return false }
        gate.stop()
        guard !gate.accepts(first), gate.currentGenerationIfAccepting() == nil else { return false }
        let second = gate.start()
        return second != first && gate.accepts(second) && !gate.accepts(first)
    }
}

@MainActor
private final class VideoUnderstandingTracker {
    struct Event {
        let kind: VideoUnderstandingEvent
        let label: String?
    }

    private struct TrackSample {
        let time: Date
        let center: CGPoint
        let area: CGFloat
    }

    private var faceSamples: [TrackSample] = []
    private var handSamples: [TrackSample] = []
    private var objectSamples: [String: [TrackSample]] = [:]
    private var objectCandidateCounts: [String: Int] = [:]
    private var lastObjectSeen: [String: Date] = [:]
    private var lastObjectPresence: [String: Bool] = [:]
    private var lastEvent: [String: Date] = [:]

    private let window: TimeInterval = 4
    private let maxSampleGap: TimeInterval = 0.9
    private let objectMissingBeforeLeft: TimeInterval = 2.0
    private let objectStableFrames = 2
    private let objectConfidenceThreshold: Float = 0.58

    func reset() {
        faceSamples.removeAll()
        handSamples.removeAll()
        objectSamples.removeAll()
        objectCandidateCounts.removeAll()
        lastObjectSeen.removeAll()
        lastObjectPresence.removeAll()
        lastEvent.removeAll()
    }

    func ingest(face: VisionSensor.FaceSignals,
                hand: VisionSensor.HandSignals,
                objects: [VisionObjectObservation],
                now: Date) -> [Event] {
        trim(now: now)
        var events: [Event] = []

        if face.present, let center = face.center, let area = face.area {
            if let last = faceSamples.last, now.timeIntervalSince(last.time) > maxSampleGap {
                faceSamples.removeAll()
            }
            faceSamples.append(TrackSample(time: now, center: center, area: area))
            events += faceMotionEvents(now: now)
        } else {
            faceSamples.removeAll()
        }
        if let center = hand.center, let area = hand.area {
            if let last = handSamples.last, now.timeIntervalSince(last.time) > maxSampleGap {
                handSamples.removeAll()
            }
            handSamples.append(TrackSample(time: now, center: center, area: area))
            events += handMotionEvents(now: now)
        } else {
            handSamples.removeAll()
        }
        events += objectMotionEvents(objects: objects, now: now)
        return events
    }

    private func faceMotionEvents(now: Date) -> [Event] {
        guard let first = faceSamples.first, let last = faceSamples.last,
              last.time.timeIntervalSince(first.time) >= 1.0 else { return [] }
        var events: [Event] = []
        let dx = last.center.x - first.center.x
        let areaDelta = ratioDelta(from: first.area, to: last.area)
        if areaDelta > 0.55, canEmit("personApproached", now: now, cooldown: 10) {
            events.append(Event(kind: .personApproached, label: nil))
        } else if areaDelta < -0.38, canEmit("personMovedAway", now: now, cooldown: 10) {
            events.append(Event(kind: .personMovedAway, label: nil))
        }
        if dx > 0.22, canEmit("personMovedRight", now: now, cooldown: 8) {
            events.append(Event(kind: .personMovedRight, label: nil))
        } else if dx < -0.22, canEmit("personMovedLeft", now: now, cooldown: 8) {
            events.append(Event(kind: .personMovedLeft, label: nil))
        }
        return events
    }

    private func handMotionEvents(now: Date) -> [Event] {
        guard let first = handSamples.first, let last = handSamples.last,
              last.time.timeIntervalSince(first.time) >= 0.6 else { return [] }
        let areaDelta = ratioDelta(from: first.area, to: last.area)
        if areaDelta > 1.1, canEmit("handReachedTowardCamera", now: now, cooldown: 8) {
            return [Event(kind: .handReachedTowardCamera, label: nil)]
        }
        return []
    }

    private func objectMotionEvents(objects: [VisionObjectObservation], now: Date) -> [Event] {
        var events: [Event] = []
        let strongestObjects = strongestObjectByLabel(from: objects)
        let visible = Set(strongestObjects.keys)
        for label in objectCandidateCounts.keys where !visible.contains(label) {
            objectCandidateCounts[label] = 0
        }
        for (label, object) in strongestObjects {
            objectCandidateCounts[label, default: 0] += 1
            guard objectCandidateCounts[label, default: 0] >= objectStableFrames else { continue }

            lastObjectSeen[label] = now
            if lastObjectPresence[label] != true, canEmit("objectAppeared.\(label)", now: now, cooldown: 20) {
                events.append(Event(kind: .objectAppeared, label: VisionObjectObservation.localizedLabel(label)))
            }
            lastObjectPresence[label] = true
            if let center = object.center, let area = object.area {
                if let last = objectSamples[label]?.last, now.timeIntervalSince(last.time) > maxSampleGap {
                    objectSamples[label] = []
                }
                objectSamples[label, default: []].append(TrackSample(time: now, center: center, area: area))
                if let moved = objectMovedEvent(label: label, now: now) {
                    events.append(moved)
                }
            }
        }
        for (label, wasVisible) in lastObjectPresence where wasVisible && !visible.contains(label) {
            guard let lastSeen = lastObjectSeen[label],
                  now.timeIntervalSince(lastSeen) > objectMissingBeforeLeft,
                  canEmit("objectDisappeared.\(label)", now: now, cooldown: 20) else { continue }
            lastObjectPresence[label] = false
            objectSamples.removeValue(forKey: label)
            events.append(Event(kind: .objectDisappeared, label: VisionObjectObservation.localizedLabel(label)))
        }
        return events
    }

    private func strongestObjectByLabel(from objects: [VisionObjectObservation]) -> [String: VisionObjectObservation] {
        var strongest: [String: VisionObjectObservation] = [:]
        for object in objects where object.confidence >= objectConfidenceThreshold {
            let label = object.label.lowercased()
            if let current = strongest[label], current.confidence >= object.confidence {
                continue
            }
            strongest[label] = object
        }
        return strongest
    }

    private func objectMovedEvent(label: String, now: Date) -> Event? {
        guard let samples = objectSamples[label],
              let first = samples.first,
              let last = samples.last,
              last.time.timeIntervalSince(first.time) >= 1.0 else { return nil }
        let dist = hypot(last.center.x - first.center.x, last.center.y - first.center.y)
        guard dist > 0.22,
              canEmit("objectMoved.\(label)", now: now, cooldown: 18) else { return nil }
        return Event(kind: .objectMoved, label: VisionObjectObservation.localizedLabel(label))
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        faceSamples.removeAll { $0.time < cutoff }
        handSamples.removeAll { $0.time < cutoff }
        for key in objectSamples.keys {
            objectSamples[key]?.removeAll { $0.time < cutoff }
            if objectSamples[key]?.isEmpty == true {
                objectSamples.removeValue(forKey: key)
            }
        }
    }

    private func ratioDelta(from old: CGFloat, to new: CGFloat) -> CGFloat {
        guard old > 0 else { return 0 }
        return (new - old) / old
    }

    private func canEmit(_ key: String, now: Date, cooldown: TimeInterval) -> Bool {
        guard now.timeIntervalSince(lastEvent[key] ?? .distantPast) >= cooldown else { return false }
        lastEvent[key] = now
        return true
    }
}

private final class LocalObjectRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private var model: VNCoreMLModel?

    var available: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }

    init() {
        let modelURL = Paths.modelsDir.appendingPathComponent("gugu-objects.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            // Not installed is a normal, expected state — object recognition stays
            // off and the pet never claims to see specific objects. Record it so
            // the audit page can guide the owner on how to enable it.
            Log.info("vision", "未安装本地物品识别模型(可选);把编译好的模型放到 \(modelURL.path) 即可启用")
            Audit.record(kind: "vision.object_model",
                         summary: "本地物品识别未启用:未安装模型(可选功能)",
                         detail: ["expected_path": modelURL.path,
                                  "how_to_enable": "把编译好的 Core ML 模型命名为 gugu-objects.mlmodelc 放入 models/ 目录"])
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            let visionModel = try VNCoreMLModel(for: model)
            self.model = visionModel
            Log.info("vision", "本地物品识别模型已加载:\(modelURL.path)")
            Audit.record(kind: "vision.object_model", summary: "本地物品识别已启用",
                         detail: ["path": modelURL.path])
        } catch {
            Log.info("vision", "本地物品识别模型加载失败:\(error)")
            Audit.record(kind: "vision.object_model",
                         summary: "本地物品识别未启用:模型加载失败",
                         detail: ["path": modelURL.path, "error": "\(error)"])
        }
    }

    func makeRecognitionRequest() -> VNCoreMLRequest? {
        lock.lock()
        let model = self.model
        lock.unlock()
        guard let model else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        return request
    }

    func results(from request: VNRequest?) -> [VisionObjectObservation] {
        guard let results = request?.results else { return [] }
        if let objects = results as? [VNRecognizedObjectObservation] {
            return objects.compactMap { observation in
                guard let label = observation.labels.first else { return nil }
                return VisionObjectObservation(
                    label: label.identifier,
                    confidence: label.confidence,
                    center: CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY),
                    area: observation.boundingBox.width * observation.boundingBox.height
                )
            }
        }
        if let classifications = results as? [VNClassificationObservation] {
            return classifications.prefix(3).map {
                VisionObjectObservation(label: $0.identifier, confidence: $0.confidence)
            }
        }
        return []
    }
}

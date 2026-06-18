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
        concreteLabel(label) ?? label
    }

    /// 把内置分类器的英文标识符映射成我们关心的"具体物品"中文名;不认得返回 nil。
    /// 用模糊包含匹配,容忍内置分类法里 cup/coffee_cup/mug 这类同义变体。
    static func concreteLabel(_ identifier: String) -> String? {
        let id = identifier.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { id.contains($0) } }
        if has("cat") { return "猫" }
        if has("dog", "puppy") { return "狗" }
        if has("cup", "mug", "coffee") { return "杯子" }
        if has("telephone", "cellphone", "smartphone", "mobile phone") || id == "phone" { return "手机" }
        if has("laptop", "notebook computer", "notebook_computer") { return "笔记本电脑" }
        if has("keyboard") { return "键盘" }
        if id.contains("mouse") && !id.contains("mousepad") { return "鼠标" }
        if has("book") { return "书" }
        if has("bottle", "flask", "thermos") { return "瓶子" }
        if has("houseplant", "potted plant", "flower", "plant") { return "植物" }
        if has("spectacle", "eyeglass", "sunglass", "eyewear") || id == "glasses" { return "眼镜" }
        if has("headphone", "earphone", "headset") { return "耳机" }
        if has("teddy", "plush", "stuffed") { return "玩偶" }
        if has("banana") { return "香蕉" }
        if id.contains("apple") && !id.contains("pineapple") { return "苹果" }
        if has("hat", "cap ", "beanie") { return "帽子" }
        return nil
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
    private let objectRecognizer = BuiltInRecognizer()
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
    private var palmXHistory: [(t: Date, x: CGFloat)] = []   // 张掌时手心 x 轨迹,用于判挥手(来回摆)
    private var expressionStreak: [VisionExpression: Int] = [:]  // 表情连续命中帧数(去抖,防打哈欠误判为笑)
    private var faceMissingStreak = 0                          // 连续看不到脸的帧数(离开需连续多帧,防闪烁)
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
            session.sessionPreset = .medium   // 480p:够人脸/presence,也够手部与物品识别(.low 太糊)
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
        // 物品识别是"重活",没必要每帧跑:最多 ~2Hz,省 CPU/电。
        let runObjects = VisionPerformancePolicy.allowsObjectRecognition
            && frameGate.allowObjectRun(minInterval: 0.5)
        let objectRequests = runObjects ? objectRecognizer.makeRequests() : []
        requests.append(contentsOf: objectRequests)
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
        let objects = (didPerform && runObjects) ? objectRecognizer.results(from: objectRequests) : []
        if let stats = frameGate.recordFrame(objectFrame: runObjects) {
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

        // 出现/离开:出现要灵敏,离开要"连续看不到几帧"才算,避免单帧丢脸造成闪烁。
        if face.present {
            faceMissingStreak = 0
            if !facePresent, now.timeIntervalSince(lastPresenceChange) > 4 {
                facePresent = true
                lastPresenceChange = now
                onPresence?(true)
            }
        } else {
            faceMissingStreak += 1
            if facePresent, faceMissingStreak >= 5, now.timeIntervalSince(lastPresenceChange) > 4 {
                facePresent = false
                lastPresenceChange = now
                onPresence?(false)
            }
        }

        // 表情去抖:连续 3 帧都命中才算,单帧的"打哈欠像笑/说话像惊讶"会被滤掉。
        let detected = Set(face.expressions)
        for e in [VisionExpression.smile, .surprised, .sleepy] {
            if detected.contains(e) { expressionStreak[e, default: 0] += 1 } else { expressionStreak[e] = 0 }
        }
        for expression in face.expressions where expressionStreak[expression, default: 0] >= 3 {
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
        faceMissingStreak = 0
        lastPresenceChange = .distantPast
        gestureCandidate = nil
        gestureCandidateCount = 0
        palmXHistory.removeAll()
        expressionStreak.removeAll()
        lastObjectLabels.removeAll()
        videoTracker.reset()
    }

    private func stableGesture(from hand: HandSignals, now: Date) -> VisionGesture? {
        guard let gesture = hand.gesture else {
            gestureCandidate = nil
            gestureCandidateCount = 0
            palmXHistory.removeAll()
            return nil
        }

        // 挥手:张掌时手心来回摆(≥2 次方向反转 + 一定幅度),而不是横移一下就算。
        if gesture == .openPalm, let center = hand.center {
            palmXHistory.append((now, center.x))
            palmXHistory.removeAll { now.timeIntervalSince($0.t) > 1.2 }
            if VisionSensor.isWaving(palmXHistory) {
                gestureCandidate = nil
                gestureCandidateCount = 0
                palmXHistory.removeAll()
                return .wave
            }
        } else {
            palmXHistory.removeAll()
        }

        if gestureCandidate == gesture {
            gestureCandidateCount += 1
        } else {
            gestureCandidate = gesture
            gestureCandidateCount = 1
        }
        return gestureCandidateCount >= 3 ? gesture : nil   // 3 帧确认,更稳
    }

    /// 手心 x 轨迹是否构成"挥手":来回摆动至少 2 次,且横向幅度够大。
    nonisolated private static func isWaving(_ history: [(t: Date, x: CGFloat)]) -> Bool {
        guard history.count >= 4 else { return false }
        let xs = history.map(\.x)
        guard let mn = xs.min(), let mx = xs.max(), mx - mn > 0.12 else { return false }
        var reversals = 0
        var lastSign = 0
        for i in 1..<xs.count {
            let d = xs[i] - xs[i - 1]
            if abs(d) < 0.01 { continue }
            let s = d > 0 ? 1 : -1
            if lastSign != 0, s != lastSign { reversals += 1 }
            lastSign = s
        }
        return reversals >= 2
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
            // 笑:嘴够宽 + 嘴角上扬(左右嘴角高于唇竖直中线),避免打哈欠/张嘴说话被当成笑。
            if metrics.height > 0,
               metrics.width / metrics.height > 2.8,
               mouthCornersRaised(mouth.normalizedPoints) {
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

    /// 嘴角是否上扬:左右最外侧点(嘴角)的平均高度 ≥ 唇竖直中线(Vision 归一化 y 向上)。
    /// 微笑会把嘴角拉高;打哈欠/平张嘴时嘴角在中线附近或更低,可据此排除。
    nonisolated private static func mouthCornersRaised(_ points: [CGPoint]) -> Bool {
        guard let left = points.min(by: { $0.x < $1.x }),
              let right = points.max(by: { $0.x < $1.x }),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return false }
        let midY = (minY + maxY) / 2
        return (left.y + right.y) / 2 >= midY
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
    private var lastObjectRun = Date.distantPast

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
        lastObjectRun = .distantPast
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

    /// 重活(物品识别)限频:距上次允许运行 >= minInterval 才放行,否则这帧跳过。
    func allowObjectRun(minInterval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastObjectRun) >= minInterval else { return false }
        lastObjectRun = now
        return true
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

/// 内置图像识别——**不需要任何模型文件**,纯本地、开箱即用、看完即弃。
/// - VNRecognizeAnimalsRequest:内置识别猫/狗(对一只宠物鸟很搭)。
/// - VNClassifyImageRequest:内置通用分类,只挑"具体物品"白名单里的几个,
///   避免把 material/indoor 这类抽象标签也念出来。
private final class BuiltInRecognizer: @unchecked Sendable {
    /// 内置识别始终可用(无需主人安装模型)。
    var available: Bool { true }

    func makeRequests() -> [VNRequest] {
        [VNRecognizeAnimalsRequest(), VNClassifyImageRequest()]
    }

    func results(from requests: [VNRequest]) -> [VisionObjectObservation] {
        var out: [VisionObjectObservation] = []
        for req in requests {
            if let animals = req.results as? [VNRecognizedObjectObservation] {
                for obs in animals {
                    guard let label = obs.labels.first, label.confidence >= 0.5 else { continue }
                    out.append(VisionObjectObservation(
                        label: label.identifier,
                        confidence: label.confidence,
                        center: CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY),
                        area: obs.boundingBox.width * obs.boundingBox.height))
                }
            } else if let classes = req.results as? [VNClassificationObservation] {
                // classify 会吐几百个标签,且置信度偏低;只保留"够自信 + 在具体物品白名单"
                // 的前两个,并把置信度归一到能通过下游门槛(下游阈值是按高置信模型调的)。
                let picked = classes
                    .filter { $0.confidence >= 0.3 && VisionObjectObservation.concreteLabel($0.identifier) != nil }
                    .prefix(2)
                for obs in picked {
                    out.append(VisionObjectObservation(label: obs.identifier,
                                                       confidence: max(obs.confidence, 0.65)))
                }
            }
        }
        return out
    }
}

import Foundation
import GuguKernel
@preconcurrency import AVFoundation
import Vision
import CoreML
import ImageIO

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
    private var handHistory: [(t: Date, p: CGPoint)] = []   // 手中心轨迹:x 来回=挥手,y 上冲=让飞
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
    var onFrame: ((VisionFrame) -> Void)?   // 每帧连续快照 → Perception + 调试窗口

    var objectRecognitionAvailable: Bool {
        objectRecognizer.available
    }

    /// 是否加载了主人放置的物品检测模型(决定能否认猫狗以外的物品)。
    var objectModelLoaded: Bool {
        objectRecognizer.modelLoaded
    }

    /// 给调试窗口用的本机实时预览层(绑定同一个会话)。只在本机显示,不录制不上传。
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }

    /// 离线测试:对一张图片跑物品识别,返回 (原始标签, 置信度, 中文映射)。
    /// 供 `--detect <image>` 用,免摄像头即可端到端验证检测模型。
    static func debugDetect(imagePath: String) -> (loaded: Bool, results: [(label: String, conf: Float, zh: String?)]) {
        let rec = BuiltInRecognizer()
        let url = URL(fileURLWithPath: imagePath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return (rec.modelLoaded, [])
        }
        let reqs = rec.makeRequests()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform(reqs) } catch { return (rec.modelLoaded, []) }
        let raw = rec.rawResults(from: reqs)
        return (rec.modelLoaded, raw.map { ($0.label, $0.conf, VisionObjectObservation.concreteLabel($0.label)) })
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
    func requestEnable(_ completion: @escaping @MainActor @Sendable (VisionStartOutcome) -> Void) {
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

    private func configureAndStart(announce: (@MainActor @Sendable (VisionStartOutcome) -> Void)? = nil) {
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
        // 物品识别是"重活",按策略给的最小间隔限频;nil 表示当前完全不跑(关闭/过热)。
        let runObjects = VisionPerformancePolicy.objectRecognitionInterval.map {
            frameGate.allowObjectRun(minInterval: $0)
        } ?? false
        let objectRequests = runObjects ? objectRecognizer.makeRequests() : []
        requests.append(contentsOf: objectRequests)
        // macOS 内置摄像头 buffer 本来就是直立的 → 用 .up,Vision 结果即直立坐标
        // (x=水平、y=垂直),全管线一致,不需要任何手动转置。
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
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
        // 原始(未过滤)标签——调试窗口用,能看到分类器到底"看见"了什么。
        let rawObjects = (didPerform && runObjects) ? objectRecognizer.rawResults(from: objectRequests) : []
        if let stats = frameGate.recordFrame(objectFrame: runObjects) {
            Log.info("vision", stats)
        }
        // pixelBuffer goes out of scope here — nothing retained
        Task { @MainActor in
            guard self.frameGate.accepts(generation) else { return }
            self.handle(face: faceSignals, hand: handSignals, objects: objects, rawObjects: rawObjects)
        }
    }

    private func handle(face: FaceSignals, hand: HandSignals,
                        objects: [VisionObjectObservation],
                        rawObjects: [(label: String, conf: Float, rect: CGRect)] = []) {
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

        if let gesture = stableGesture(from: hand, now: now) {
            let cooldown: TimeInterval = (gesture == .flyUp) ? 2.5 : 12   // "让飞"可较快重复
            if now.timeIntervalSince(lastGesture[gesture] ?? .distantPast) > cooldown {
                lastGesture[gesture] = now
                onGesture?(gesture)
            }
        }

        for object in stableObjects(from: objects, now: now) {
            onObject?(object)
        }
        for event in videoTracker.ingest(face: face, hand: hand, objects: objects, now: now) {
            onVideoEvent?(event.kind, event.label)
        }

        if let onFrame {
            var f = VisionFrame()
            // —— 语义层(平滑后的当前状态)——
            f.ownerPresent = facePresent                       // 迟滞平滑后的"在不在"
            f.expression = [VisionExpression.smile, .surprised, .sleepy]
                .last { expressionStreak[$0, default: 0] >= 3 }?.rawValue
            f.handX = hand.center.map { 1 - $0.x }             // 指尖水平位:镜像成主人视角(0左1右)
            f.handY = hand.center.map { $0.y }                 // 指尖垂直位(Vision 直立坐标,0下1上)
            f.objectsNow = videoTracker.presentObjectLabels()  // 稳定在场集(已去抖),非每帧原始
            // —— 调试层(原始数值)——
            f.facePresent = face.present
            f.mouthWH = face.mouthWH
            f.cornerUpturn = face.cornerUpturn
            f.eyeL = face.eyeL
            f.eyeR = face.eyeR
            f.expressions = face.expressions.map(\.rawValue)
            f.rawGesture = "—"          // 静态手型识别已移除;手势只剩 wave/flyUp(运动判定)
            f.fingers = []
            f.palmSamples = handHistory.count
            f.objects = rawObjects.map { ($0.label, $0.conf) }
            f.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            f.modelLoaded = objectRecognizer.modelLoaded
            f.faceBox = face.present ? face.box : nil
            f.handBox = hand.box
            f.objectBoxes = rawObjects
            onFrame(f)
        }
    }

    private func resetTransientVisionState() {
        facePresent = false
        faceMissingStreak = 0
        lastPresenceChange = .distantPast
        handHistory.removeAll()
        expressionStreak.removeAll()
        lastObjectLabels.removeAll()
        videoTracker.reset()
    }

    private func stableGesture(from hand: HandSignals, now: Date) -> VisionGesture? {
        // 手中心轨迹(与手型无关):x 来回摆=挥手;y 单向上冲="让你飞"。
        // 关键:快挥时手会运动模糊、单帧漏检——绝不能一漏就清空轨迹,否则永远攒不满。
        guard let center = hand.center else { return nil }
        // 只有断档过久(>0.5s)才另起一段,避免把"手离开再回来"拼成假反转;
        // 短暂漏检(快挥的常态)继续累积,trim 负责老化旧样本。
        if let last = handHistory.last, now.timeIntervalSince(last.t) > 0.5 {
            handHistory.removeAll()
        }
        handHistory.append((now, center))
        handHistory.removeAll { now.timeIntervalSince($0.t) > 1.2 }
        if VisionSensor.isWaving(handHistory) {
            handHistory.removeAll()
            return .wave
        }
        if VisionSensor.isSwipeUp(handHistory) {
            handHistory.removeAll()
            return .flyUp
        }
        return nil
    }

    /// 手心 x 轨迹是否构成"挥手":来回摆动至少 2 次,且横向幅度够大。
    nonisolated private static func isWaving(_ history: [(t: Date, p: CGPoint)]) -> Bool {
        guard history.count >= 4 else { return false }
        let xs = history.map(\.p.x)
        guard let mn = xs.min(), let mx = xs.max(), mx - mn > 0.10 else { return false }
        var reversals = 0
        var lastSign = 0
        for i in 1..<xs.count {
            let d = xs[i] - xs[i - 1]
            if abs(d) < 0.008 { continue }
            let s = d > 0 ? 1 : -1
            if lastSign != 0, s != lastSign { reversals += 1 }
            lastSign = s
        }
        return reversals >= 2
    }

    /// 手心 y 轨迹是否构成"上挥"(Vision 直立坐标 y 向上):净上移够大、且基本单向向上(不是上下抖)。
    nonisolated private static func isSwipeUp(_ history: [(t: Date, p: CGPoint)]) -> Bool {
        guard history.count >= 4, let first = history.first, let last = history.last else { return false }
        let net = last.p.y - first.p.y           // >0 = 向上
        guard net > 0.20 else { return false }
        var travel: CGFloat = 0
        for i in 1..<history.count { travel += abs(history[i].p.y - history[i - 1].p.y) }
        return travel > 0 && net / travel > 0.6  // 基本单向向上(上下抖会相互抵消)
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

    nonisolated struct FaceSignals {
        var present: Bool
        var expressions: [VisionExpression]
        var center: CGPoint?
        var area: CGFloat?
        // 调试用原始数值
        var mouthWH: CGFloat = 0      // 嘴 宽/高
        var cornerUpturn: CGFloat = 0 // 嘴角上扬(归一)
        var eyeL: CGFloat = 0         // 左眼 高/宽
        var eyeR: CGFloat = 0         // 右眼 高/宽
        var box: CGRect?              // 可视化:人脸归一化外框
    }

    nonisolated struct HandSignals {
        var center: CGPoint?
        var area: CGFloat?
        var box: CGRect?              // 可视化:手归一化外框
    }

    nonisolated private static func faceSignals(from face: VNFaceObservation?) -> FaceSignals {
        guard let face else { return FaceSignals(present: false, expressions: []) }
        var expressions: [VisionExpression] = []
        let landmarks = face.landmarks
        var mouthWH: CGFloat = 0, upturnDbg: CGFloat = 0, eyeLDbg: CGFloat = 0, eyeRDbg: CGFloat = 0
        if let mouth = landmarks?.outerLips, let metrics = landmarkMetrics(mouth.normalizedPoints) {
            let upturn = mouthCornerUpturn(mouth.normalizedPoints)
            upturnDbg = upturn
            mouthWH = metrics.height > 0 ? metrics.width / metrics.height : 0
            if upturn > 0.035 {
                expressions.append(.smile)
            } else if metrics.width > 0, metrics.height / metrics.width > 0.65 {
                expressions.append(.surprised)   // 仅很圆很竖的"O"形嘴,且没在笑
            }
        }
        if let leftEye = landmarks?.leftEye,
           let rightEye = landmarks?.rightEye,
           let left = landmarkMetrics(leftEye.normalizedPoints),
           let right = landmarkMetrics(rightEye.normalizedPoints),
           left.width > 0,
           right.width > 0 {
            eyeLDbg = left.height / left.width
            eyeRDbg = right.height / right.width
            if eyeLDbg < 0.16, eyeRDbg < 0.16 {
                expressions.append(.sleepy)
            }
        }
        return FaceSignals(present: true,
                           expressions: expressions,
                           center: CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY),
                           area: face.boundingBox.width * face.boundingBox.height,
                           mouthWH: mouthWH, cornerUpturn: upturnDbg, eyeL: eyeLDbg, eyeR: eyeRDbg,
                           box: face.boundingBox)
    }

    nonisolated private static func landmarkMetrics(_ points: [CGPoint]) -> (width: CGFloat, height: CGFloat)? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return (maxX - minX, maxY - minY)
    }

    /// 嘴角上扬幅度(按嘴宽归一):左右嘴角平均高度减去唇竖直中线,正值=上扬(笑)。
    /// Vision 归一化坐标 y 向上,所以嘴角越高值越大。
    nonisolated private static func mouthCornerUpturn(_ points: [CGPoint]) -> CGFloat {
        guard let left = points.min(by: { $0.x < $1.x }),
              let right = points.max(by: { $0.x < $1.x }),
              let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return 0 }
        let midY = (minY + maxY) / 2
        let width = max(maxX - minX, 0.01)
        return ((left.y + right.y) / 2 - midY) / width
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
        // 追"指尖":优先食指尖(指向时最稳),退到中指尖、再退到手腕——
        // 只要画面里有手就有一个可追的点,不强求 4 指都识别到(1~2 根手指也行)。
        guard let tip = point(.indexTip) ?? point(.middleTip) ?? point(.wrist) else {
            return HandSignals()
        }
        let allPoints = points.values.filter { $0.confidence >= minConfidence }.map(\.location)
        // center 即指尖:供"位置→跟随"和"运动→挥手/上挥"两条路径用。
        return HandSignals(center: tip, area: boundingArea(allPoints), box: boundingBox(allPoints))
    }

    nonisolated private static func boundingArea(_ points: [CGPoint]) -> CGFloat? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    nonisolated private static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

private enum VisionPerformancePolicy {
    /// 物品识别的最小运行间隔(秒);返回 nil 表示当前完全不跑。
    /// 用户显式关闭、或机器过热 → 停;低电量 → 不停,只降频(从 ~2Hz 降到 ~0.7Hz)。
    static var objectRecognitionInterval: TimeInterval? {
        if UserDefaults.standard.object(forKey: "gugu.vision.objects.enabled") != nil,
           !UserDefaults.standard.bool(forKey: "gugu.vision.objects.enabled") {
            return nil   // 主人显式关掉了
        }
        let info = ProcessInfo.processInfo
        switch info.thermalState {
        case .serious, .critical:
            return nil   // 过热才完全停
        default:
            return info.isLowPowerModeEnabled ? 1.5 : 0.5
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

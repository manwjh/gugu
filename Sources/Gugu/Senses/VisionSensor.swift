import Foundation
import GuguKernel
@preconcurrency import AVFoundation
import Vision
import CoreML
import ImageIO

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
    case flyUp   // 手向上一挥:让咕咕飞一个

    var eventKind: String { "gesture_\(rawValue)" }

    var summary: String {
        switch self {
        case .wave: return "你看见主人向你挥手"
        case .openPalm: return "你看见主人把手掌伸给你看"
        case .thumbsUp: return "你看见主人竖起了大拇指"
        case .ok: return "你看见主人比了一个 OK 手势"
        case .pointing: return "你看见主人伸出手指指了指"
        case .flyUp: return "你看见主人把手往上一挥,像是让你飞起来"
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

    /// 把检测/分类标识符映射成我们关心的"具体物品"中文名;不认得返回 nil。
    /// 模糊包含匹配,兼容 COCO 名(如 "cell phone" 带空格)与同义变体。
    static func concreteLabel(_ identifier: String) -> String? {
        let id = identifier.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { id.contains($0) } }
        if has("cat") { return "猫" }
        if has("dog", "puppy") { return "狗" }
        if has("bird") { return "鸟" }
        if has("phone") { return "手机" }                 // cell phone / telephone / smartphone
        if has("laptop", "notebook computer") { return "笔记本电脑" }
        if has("keyboard") { return "键盘" }
        if has("remote") { return "遥控器" }
        if id == "tv" || has("television", "monitor") { return "屏幕" }
        if id.contains("mouse") && !id.contains("mousepad") { return "鼠标" }
        if has("wine glass") { return "酒杯" }
        if has("cup", "mug", "coffee") { return "杯子" }
        if has("bottle", "flask", "thermos") { return "瓶子" }
        if has("bowl") { return "碗" }
        if has("fork", "knife", "spoon") { return "餐具" }
        if has("book") { return "书" }
        if has("scissors") { return "剪刀" }
        if has("toothbrush") { return "牙刷" }
        if has("clock", "watch") { return "钟表" }
        if has("vase") { return "花瓶" }
        if has("houseplant", "potted plant", "flower", "plant") { return "植物" }
        if has("spectacle", "eyeglass", "sunglass", "eyewear") || id == "glasses" { return "眼镜" }
        if has("headphone", "earphone", "headset") { return "耳机" }
        if has("teddy", "plush", "stuffed") { return "玩偶" }
        if has("banana") { return "香蕉" }
        if has("orange") && !has("orangutan") { return "橙子" }
        if id.contains("apple") && !id.contains("pineapple") { return "苹果" }
        if has("hat", "beanie") { return "帽子" }
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

/// 每帧的视觉快照——视觉感知的**唯一连续真相源**。
/// 既喂感知上下文(Perception 的视觉字段全部出自这里,语义已平滑),
/// 也喂调试窗口(下半部分的原始数值/外框,用于调阈值)。
struct VisionFrame {
    // —— 语义层(已平滑,给 Perception 连续读)——
    var ownerPresent = false              // 经迟滞平滑的"主人在不在"
    var expression: String?               // 当前表情(连续 3 帧确认;无=中性)
    var gesture: String?                  // 当前保持的手型(2 帧确认;无=没摆手型)
    var handX: CGFloat?                    // 手水平位置 0=左 1=右(主人视角,已镜像)
    var objectsNow: [String] = []         // 当前稳定在场的具体物品(中文名;已去抖,非每帧原始)

    // —— 调试层(原始数值,给调试窗口调阈值)——
    var facePresent = false               // 本帧原始是否检到脸(画外框用)
    var mouthWH: CGFloat = 0
    var cornerUpturn: CGFloat = 0
    var eyeL: CGFloat = 0
    var eyeR: CGFloat = 0
    var expressions: [String] = []        // 本帧检测到(去抖前)
    var rawGesture: String = "—"          // 本帧原始手型
    var fingers: [Bool] = []              // 食/中/无名/小
    var palmSamples = 0                   // 手轨迹缓冲帧数
    var objects: [(label: String, conf: Float)] = []
    var lowPower = false
    var modelLoaded = false
    // 可视化用:归一化外框(Vision 坐标,原点左下)
    var faceBox: CGRect?
    var handBox: CGRect?
    var objectBoxes: [(label: String, conf: Float, rect: CGRect)] = []
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
            f.gesture = gestureCandidateCount >= 2 ? gestureCandidate?.rawValue : nil
            f.handX = hand.box.map { 1 - $0.midX }             // 镜像成主人视角,收口在此
            f.objectsNow = videoTracker.presentObjectLabels()  // 稳定在场集(已去抖),非每帧原始
            // —— 调试层(原始数值)——
            f.facePresent = face.present
            f.mouthWH = face.mouthWH
            f.cornerUpturn = face.cornerUpturn
            f.eyeL = face.eyeL
            f.eyeR = face.eyeR
            f.expressions = face.expressions.map(\.rawValue)
            f.rawGesture = hand.gesture?.rawValue ?? "—"
            f.fingers = hand.fingers
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
        gestureCandidate = nil
        gestureCandidateCount = 0
        handHistory.removeAll()
        expressionStreak.removeAll()
        lastObjectLabels.removeAll()
        videoTracker.reset()
    }

    private func stableGesture(from hand: HandSignals, now: Date) -> VisionGesture? {
        // 手中心轨迹(与手型无关):x 来回摆=挥手;y 单向上冲="让你飞"。
        // 关键:快挥时手会运动模糊、单帧漏检——绝不能一漏就清空轨迹,否则永远攒不满。
        if let center = hand.center {
            // 只有断档过久(>0.5s)才另起一段,避免把"手离开再回来"拼成假反转;
            // 短暂漏检(快挥的常态)继续累积,trim 负责老化旧样本。
            if let last = handHistory.last, now.timeIntervalSince(last.t) > 0.5 {
                handHistory.removeAll()
            }
            handHistory.append((now, center))
            handHistory.removeAll { now.timeIntervalSince($0.t) > 1.2 }
            if VisionSensor.isWaving(handHistory) {
                handHistory.removeAll()
                gestureCandidate = nil; gestureCandidateCount = 0
                return .wave
            }
            if VisionSensor.isSwipeUp(handHistory) {
                handHistory.removeAll()
                gestureCandidate = nil; gestureCandidateCount = 0
                return .flyUp
            }
        }
        // 注:不在"看不到手"时清空 handHistory——漏检的那几帧靠 1.2s trim 自然老化。

        guard let gesture = hand.gesture else {
            gestureCandidate = nil
            gestureCandidateCount = 0
            return nil
        }

        if gestureCandidate == gesture {
            gestureCandidateCount += 1
        } else {
            gestureCandidate = gesture
            gestureCandidateCount = 1
        }
        return gestureCandidateCount >= 2 ? gesture : nil   // 2 帧确认
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

    nonisolated fileprivate struct FaceSignals {
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

    nonisolated fileprivate struct HandSignals {
        var gesture: VisionGesture?
        var center: CGPoint?
        var area: CGFloat?
        var fingers: [Bool] = []      // 调试用:食/中/无名/小 是否伸直
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
        let handBox = boundingBox(allPoints)
        let palmSpan = max(0.05, hypot(indexTip.x - littleTip.x, indexTip.y - littleTip.y))
        // 手指是否伸直:指尖比第二关节(PIP)离手腕更远 → 直;比掌跨参照更稳,握拳时不误判。
        // PIP 缺失时回退到旧的掌跨比值法。
        func extended(_ tip: CGPoint,
                      _ pipName: VNHumanHandPoseObservation.JointName,
                      fallback: CGFloat) -> Bool {
            if let pip = point(pipName) {
                return distance(tip, wrist) > distance(pip, wrist) * 1.08
            }
            return distance(tip, wrist) > palmSpan * fallback
        }
        let indexExtended = extended(indexTip, .indexPIP, fallback: 1.35)
        let middleExtended = extended(middleTip, .middlePIP, fallback: 1.25)
        let ringExtended = extended(ringTip, .ringPIP, fallback: 1.15)
        let littleExtended = extended(littleTip, .littlePIP, fallback: 1.05)
        let fingers = [indexExtended, middleExtended, ringExtended, littleExtended]

        if let thumbTip = point(.thumbTip), distance(thumbTip, indexTip) < palmSpan * 0.42 {
            return HandSignals(gesture: .ok, center: center, area: handArea, fingers: fingers, box: handBox)
        }
        if indexExtended && middleExtended && ringExtended && littleExtended {
            return HandSignals(gesture: .openPalm, center: center, area: handArea, fingers: fingers, box: handBox)
        }
        if indexExtended && !middleExtended && !ringExtended && !littleExtended {
            return HandSignals(gesture: .pointing, center: center, area: handArea, fingers: fingers, box: handBox)
        }
        // 竖大拇指:其余手指基本握起 + 拇指明显在最上方。
        if let thumbTip = point(.thumbTip),
           !middleExtended, !ringExtended, !littleExtended,
           thumbTip.y > max(indexTip.y, middleTip.y, ringTip.y, littleTip.y) + 0.05 {
            return HandSignals(gesture: .thumbsUp, center: center, area: handArea, fingers: fingers, box: handBox)
        }
        return HandSignals(center: center, area: handArea, fingers: fingers, box: handBox)
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

    nonisolated private static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
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

    /// 当前稳定在场的物品(中文名)——已过去抖/置信门控的状态,供 Perception 连续读。
    /// 与 objectAppeared 事件同源,只是这里给"此刻在场",那里给"刚出现"。
    func presentObjectLabels() -> [String] {
        lastObjectPresence.filter { $0.value }.keys
            .map { VisionObjectObservation.localizedLabel($0) }.sorted()
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

/// 本地物品识别。优先用主人放置的目标检测模型(YOLO 类,COCO 80 类,能认手持的杯子/手机/书…);
/// 没有模型时退回系统内置的动物检测(只认猫/狗)。全部纯本地、看完即弃、不需要联网。
/// 检测模型查找位置(任选其一,命名 gugu-objects):app 包 Resources 或 ~/.../Gugu/models/,
/// 支持 .mlmodelc / .mlmodel / .mlpackage(后两者运行时自动编译)。
private final class BuiltInRecognizer: @unchecked Sendable {
    private let detectionModel: VNCoreMLModel?

    init() { detectionModel = BuiltInRecognizer.loadDetectionModel() }

    var available: Bool { true }
    var modelLoaded: Bool { detectionModel != nil }

    func makeRequests() -> [VNRequest] {
        if let detectionModel {
            let r = VNCoreMLRequest(model: detectionModel)
            r.imageCropAndScaleOption = .scaleFill   // 与 Ultralytics iOS 示例一致
            return [r]
        }
        return [VNRecognizeAnimalsRequest()]         // 无模型:至少认猫/狗
    }

    func results(from requests: [VNRequest]) -> [VisionObjectObservation] {
        var out: [VisionObjectObservation] = []
        for req in requests {
            guard let objects = req.results as? [VNRecognizedObjectObservation] else { continue }
            for obs in objects {
                guard let label = obs.labels.first, label.confidence >= 0.35 else { continue }
                // 只上报我们关心、且有中文名的具体物(过滤掉 person 等)。
                guard VisionObjectObservation.concreteLabel(label.identifier) != nil else { continue }
                out.append(VisionObjectObservation(
                    label: label.identifier,
                    confidence: label.confidence,
                    center: CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY),
                    area: obs.boundingBox.width * obs.boundingBox.height))
            }
        }
        return out
    }

    /// 调试用:未过滤的原始检测(含 person 等),按置信度取前几个,带归一化外框。
    func rawResults(from requests: [VNRequest]) -> [(label: String, conf: Float, rect: CGRect)] {
        var out: [(String, Float, CGRect)] = []
        for req in requests {
            guard let objects = req.results as? [VNRecognizedObjectObservation] else { continue }
            for obs in objects where obs.labels.first != nil {
                out.append((obs.labels.first!.identifier, obs.labels.first!.confidence, obs.boundingBox))
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(8).map { $0 }
    }

    private static func loadDetectionModel() -> VNCoreMLModel? {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        var candidates: [URL] = []
        for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
            if let u = Bundle.main.url(forResource: "gugu-objects", withExtension: ext) { candidates.append(u) }
            candidates.append(Paths.modelsDir.appendingPathComponent("gugu-objects.\(ext)"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                // .mlmodelc 直接加载;.mlpackage/.mlmodel 先编译。
                let loadURL = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
                let model = try MLModel(contentsOf: loadURL, configuration: cfg)
                let vm = try VNCoreMLModel(for: model)
                Log.info("vision", "物品检测模型已加载:\(url.lastPathComponent)")
                Audit.record(kind: "vision.object_model", summary: "物品检测模型已加载",
                             detail: ["file": url.lastPathComponent])
                return vm
            } catch {
                Log.info("vision", "物品检测模型加载失败(\(url.lastPathComponent)):\(error)")
            }
        }
        Log.info("vision", "未放置物品检测模型;只认猫/狗。放入 models/gugu-objects.mlpackage 可认更多物品")
        return nil
    }
}

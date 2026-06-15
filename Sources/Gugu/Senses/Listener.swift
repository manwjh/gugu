import Foundation
import Speech
import AVFoundation

/// 本地语音识别(STT)+ 唤醒词。
/// 隐私:requiresOnDeviceRecognition = true,完全本机识别,不上传任何音频或文字。
/// 工作方式:菜单栏开启后,持续做本地识别,但只在听到唤醒词"咕咕/股股/咕咕鸟"后,
/// 把唤醒词之后那一句话作为"指令"回调出去;没听到唤醒词的内容一律丢弃、不处理。
@MainActor
final class Listener: NSObject {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false

    private var lastCommandAt = Date.distantPast
    private var consumedPrefixLen = 0

    /// 唤醒词后听到的一句指令(已去掉唤醒词本身)。
    var onCommand: ((String) -> Void)?
    /// 刚听到唤醒词、开始留意时的轻回调(可用于让鸟抬头)。
    var onWake: (() -> Void)?

    private static let wakeWords = ["咕咕", "股股", "古古", "咕咕鸟", "小咕"]

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.listen.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.listen.enabled")
              if newValue { startIfPossible() } else { stop() } }
    }

    func startIfPossible() {
        guard enabled, !running else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    Log.info("listen", "语音识别未授权(系统设置→隐私→语音识别)")
                    return
                }
                self?.requestMicAndStart()
            }
        }
    }

    private func requestMicAndStart() {
        // 麦克风权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                Task { @MainActor in if ok { self?.beginSession() } }
            }
        default:
            Log.info("listen", "麦克风未授权")
        }
    }

    private func beginSession() {
        guard !running, let recognizer, recognizer.isAvailable else {
            Log.info("listen", "识别器不可用")
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            Log.info("listen", "当前系统/语言不支持本机语音识别,咕咕不会启用麦克风监听")
            enabled = false
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // 本机识别,不上传
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.info("listen", "麦克风启动失败: \(error)")
            return
        }
        running = true
        consumedPrefixLen = 0
        Log.info("listen", "咕咕竖起耳朵了(只在本机听,听完即忘)")

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.handleTranscript(text, isFinal: result.isFinal) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.restartSoon() }
            }
        }
    }

    /// 在连续识别文本里找唤醒词,截取其后的内容作为指令。
    private func handleTranscript(_ full: String, isFinal: Bool) {
        // 只看尚未消费的尾部,避免重复触发
        let tailStart = full.index(full.startIndex, offsetBy: min(consumedPrefixLen, full.count))
        let tail = String(full[tailStart...])

        guard let range = Listener.findWake(in: tail) else { return }
        onWake?()
        let command = String(tail[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,，。!！?？、"))

        // 指令太短先等等(可能还在说),最终结果才发
        if command.count < 1 { return }
        if !isFinal && command.count < 2 { return }

        // 防抖:2 秒内不重复触发
        guard Date().timeIntervalSince(lastCommandAt) > 2 else { return }
        lastCommandAt = Date()
        // 标记已消费到当前长度
        consumedPrefixLen = full.count
        Log.info("listen", "听到指令:\(command)")
        onCommand?(command)
    }

    private static func findWake(in s: String) -> Range<String.Index>? {
        for w in wakeWords {
            if let r = s.range(of: w) { return r }
        }
        return nil
    }

    private func restartSoon() {
        guard enabled else { return }
        stop(keepEnabled: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.beginSession()
        }
    }

    func stop(keepEnabled: Bool = false) {
        guard running || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        running = false
        if !keepEnabled { Log.info("listen", "咕咕不听了") }
    }
}

import Foundation
import Speech
import AVFoundation

enum ListenerStatus: Equatable {
    case off
    case starting
    case listening
    case muted
    case unavailable(String)
}

/// 本地语音识别(STT)+ 持续语音会话。
/// 隐私:requiresOnDeviceRecognition = true,完全本机识别,不上传任何音频或文字。
/// 工作方式:菜单栏开启后,直到主人关闭麦克风前,都把主人说出的短句当作语音输入。
/// 唤醒词"咕咕/股股/咕咕鸟"仍然可用,但不再是每句话的硬性前缀。
@MainActor
final class Listener: NSObject {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: L.current == .zh ? "zh-CN" : "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false

    private var lastCommandAt = Date.distantPast
    private var lastCommandFingerprint = ""
    private var consumedPrefixLen = 0
    private var pendingDispatch: DispatchWorkItem?
    private var unmuteDispatch: DispatchWorkItem?
    private var lastTranscript = ""
    private var mutedUntil = Date.distantPast
    private(set) var status: ListenerStatus = .off

    /// 唤醒词后听到的一句指令(已去掉唤醒词本身)。
    var onCommand: ((String) -> Void)?
    var onStateChange: ((ListenerStatus) -> Void)?
    /// 刚听到唤醒词、开始留意时的轻回调(可用于让鸟抬头)。
    var onWake: (() -> Void)?

    private static var wakeWords: [String] { L.wakeWords }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.listen.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.listen.enabled")
              if newValue {
                  setStatus(.starting)
                  startIfPossible()
              } else {
                  stop()
              } }
    }

    func startIfPossible() {
        guard enabled, !running else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    Log.info("listen", "语音识别未授权(系统设置→隐私→语音识别)")
                    self?.disable(reason: "语音识别未授权")
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
                Task { @MainActor in
                    if ok {
                        self?.beginSession()
                    } else {
                        self?.disable(reason: "麦克风未授权")
                    }
                }
            }
        default:
            Log.info("listen", "麦克风未授权")
            disable(reason: "麦克风未授权")
        }
    }

    private func beginSession() {
        guard !running, let recognizer, recognizer.isAvailable else {
            Log.info("listen", "识别器不可用")
            disable(reason: "识别器不可用")
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            Log.info("listen", "当前系统/语言不支持本机语音识别,咕咕不会启用麦克风监听")
            disable(reason: "本机语音识别不可用")
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
            disable(reason: "麦克风启动失败")
            return
        }
        running = true
        consumedPrefixLen = 0
        lastTranscript = ""
        pendingDispatch?.cancel()
        Log.info("listen", "咕咕竖起耳朵了(只在本机听,听完即忘)")
        setStatus(Date() < mutedUntil ? .muted : .listening)

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

    /// 在连续识别文本里截取尚未消费的一句短话。唤醒词可选。
    private func handleTranscript(_ full: String, isFinal: Bool) {
        lastTranscript = full
        guard Date() >= mutedUntil else {
            consume(full)
            return
        }
        guard let command = commandCandidate(from: full) else { return }
        if isFinal {
            dispatch(command, consumedLength: full.count)
        } else {
            // 句末已带终止标点 → 这一句多半说完了,几乎立刻派发;否则用较短的防抖等后续字。
            let delay = Listener.endsSentence(full) ? 0.2 : 0.5
            scheduleDispatch(command, consumedLength: full.count, after: delay)
        }
    }

    /// partial 文本是否以句末标点收尾(说明这句大概率讲完了)。
    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: "。!！?？;；").contains(last)
    }

    private static func findWake(in s: String) -> Range<String.Index>? {
        let haystack = s.lowercased()
        for w in wakeWords {
            if let r = haystack.range(of: w.lowercased()) {
                // map the lowercased range back onto the original string by offset
                let lower = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
                let upper = haystack.distance(from: haystack.startIndex, to: r.upperBound)
                let start = s.index(s.startIndex, offsetBy: lower)
                let end = s.index(s.startIndex, offsetBy: upper)
                return start..<end
            }
        }
        return nil
    }

    private func commandCandidate(from full: String) -> String? {
        let safePrefix = min(consumedPrefixLen, full.count)
        let tailStart = full.index(full.startIndex, offsetBy: safePrefix)
        var tail = String(full[tailStart...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,，。!！?？、"))
        guard !tail.isEmpty else { return nil }

        if let range = Listener.findWake(in: tail) {
            onWake?()
            tail = String(tail[range.upperBound...])
        }
        let command = Listener.cleanCommand(tail)
        guard command.count >= 2 else { return nil }
        return command
    }

    private static func cleanCommand(_ raw: String) -> String {
        let droppedPrefixes = wakeWords
        var out = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,，。!！?？、"))
        for prefix in droppedPrefixes where out.hasPrefix(prefix) {
            out.removeFirst(prefix.count)
            out = out.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,，。!！?？、"))
            break
        }
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        if out.count > 120 {
            out = String(out.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private func scheduleDispatch(_ command: String, consumedLength: Int, after delay: TimeInterval = 0.5) {
        pendingDispatch?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, Date() >= self.mutedUntil else { return }
                self.dispatch(command, consumedLength: max(consumedLength, self.lastTranscript.count))
            }
        }
        pendingDispatch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func dispatch(_ command: String, consumedLength: Int) {
        pendingDispatch?.cancel()
        let fingerprint = command
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !fingerprint.isEmpty else { return }
        guard fingerprint != lastCommandFingerprint || Date().timeIntervalSince(lastCommandAt) > 3 else {
            consumedPrefixLen = max(consumedPrefixLen, consumedLength)
            return
        }
        lastCommandAt = Date()
        lastCommandFingerprint = fingerprint
        consumedPrefixLen = max(consumedPrefixLen, consumedLength)
        Log.info("listen", "听到指令:\(command)")
        onCommand?(command)
    }

    private func consume(_ full: String) {
        pendingDispatch?.cancel()
        consumedPrefixLen = max(consumedPrefixLen, full.count)
    }

    /// 咕咕自己说话时临时忽略识别结果,避免把 TTS 当成主人输入。
    func suppressInput(for seconds: TimeInterval) {
        pendingDispatch?.cancel()
        unmuteDispatch?.cancel()
        mutedUntil = max(mutedUntil, Date().addingTimeInterval(seconds))
        if !lastTranscript.isEmpty {
            consume(lastTranscript)
        }
        if enabled {
            setStatus(.muted)
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if Date() >= self.mutedUntil, self.enabled {
                        self.setStatus(self.running ? .listening : .starting)
                    }
                }
            }
            unmuteDispatch = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    /// Self-test hook: feeds deterministic transcripts without touching the microphone.
    func debugFeedTranscript(_ full: String, isFinal: Bool) {
        handleTranscript(full, isFinal: isFinal)
    }

    private func restartSoon() {
        guard enabled else { return }
        setStatus(.starting)
        stop(keepEnabled: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.beginSession()
        }
    }

    func stop(keepEnabled: Bool = false) {
        pendingDispatch?.cancel()
        pendingDispatch = nil
        unmuteDispatch?.cancel()
        unmuteDispatch = nil
        guard running || engine.isRunning else {
            consumedPrefixLen = 0
            lastTranscript = ""
            if !keepEnabled { Log.info("listen", "咕咕不听了") }
            if !keepEnabled { setStatus(.off) }
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        running = false
        consumedPrefixLen = 0
        lastTranscript = ""
        if !keepEnabled { Log.info("listen", "咕咕不听了") }
        if !keepEnabled { setStatus(.off) }
    }

    private func disable(reason: String) {
        UserDefaults.standard.set(false, forKey: "gugu.listen.enabled")
        stop(keepEnabled: true)
        Log.info("listen", reason)
        setStatus(.unavailable(reason))
    }

    private func setStatus(_ next: ListenerStatus) {
        guard status != next else { return }
        status = next
        onStateChange?(next)
    }
}

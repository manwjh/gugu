import AVFoundation
import AppKit

/// 本地语音合成(TTS)。用 AVSpeechSynthesizer,完全本地、零 token、零网络。
/// 轻微提高音调并按情绪调节语速,保留角色感但避免系统提示音般尖硬。
@MainActor
final class Voice: NSObject {
    private let synth = AVSpeechSynthesizer()
    private var chineseVoice: AVSpeechSynthesisVoice?
    var onWillSpeak: ((String) -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.voice.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.voice.enabled")
              if !newValue { synth.stopSpeaking(at: .immediate) } }
    }

    override init() {
        super.init()
        // 选一个中文嗓(优先高质量/增强版),没有就用系统默认
        let voices = AVSpeechSynthesisVoice.speechVoices()
        chineseVoice = voices.first { $0.language.hasPrefix("zh") && $0.quality == .premium }
            ?? voices.first { $0.language.hasPrefix("zh") && $0.quality == .enhanced }
            ?? voices.first { $0.language == "zh-CN" }
            ?? voices.first { $0.language.hasPrefix("zh") }
    }

    /// 说一句话。会先把括号里的舞台提示(如"歪头看了看你")去掉,只念真正说出口的字。
    func speak(_ raw: String, mood: String = "平静") {
        guard enabled else { return }
        let text = Voice.stripStageDirections(raw)
        guard !text.isEmpty else { return }
        // 抢断上一句,保证回应及时
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        onWillSpeak?(text)
        let style = VoiceStyle.forMood(mood)
        for (index, sentence) in Voice.splitSentences(text).enumerated() {
            let u = AVSpeechUtterance(string: sentence)
            u.voice = chineseVoice
            u.pitchMultiplier = style.pitch
            u.rate = AVSpeechUtteranceDefaultSpeechRate * style.rate
            u.volume = style.volume
            u.preUtteranceDelay = index == 0 ? 0 : style.pause
            u.postUtteranceDelay = style.pause * 0.4
            synth.speak(u)
        }
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// 去掉 (...)、（...）、*...* 这类舞台提示,只保留真正要念的话。
    static func stripStageDirections(_ s: String) -> String {
        var out = s
        let patterns = ["\\([^)]*\\)", "（[^）]*）", "\\*[^*]*\\*", "「", "」"]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func splitSentences(_ s: String) -> [String] {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let stops = CharacterSet(charactersIn: "。！？!?；;")
        var pieces: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if stops.contains(scalar) {
                appendSpeechPiece(current, to: &pieces)
                current = ""
            }
        }
        appendSpeechPiece(current, to: &pieces)
        return pieces.isEmpty ? [text] : pieces
    }

    private static func appendSpeechPiece(_ raw: String, to pieces: inout [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let maxChars = 28
        if trimmed.count <= maxChars {
            pieces.append(trimmed)
            return
        }
        var remaining = trimmed
        while remaining.count > maxChars {
            let cut = remaining.index(remaining.startIndex, offsetBy: maxChars)
            pieces.append(String(remaining[..<cut]))
            remaining = String(remaining[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remaining.isEmpty {
            pieces.append(remaining)
        }
    }
}

private struct VoiceStyle {
    let pitch: Float
    let rate: Float
    let volume: Float
    let pause: TimeInterval

    static func forMood(_ mood: String) -> VoiceStyle {
        switch mood {
        case "开心":
            return VoiceStyle(pitch: 1.36, rate: 1.02, volume: 0.92, pause: 0.08)
        case "好奇":
            return VoiceStyle(pitch: 1.34, rate: 0.98, volume: 0.9, pause: 0.1)
        case "心疼", "委屈":
            return VoiceStyle(pitch: 1.18, rate: 0.88, volume: 0.78, pause: 0.16)
        case "困":
            return VoiceStyle(pitch: 1.12, rate: 0.82, volume: 0.7, pause: 0.2)
        case "无聊":
            return VoiceStyle(pitch: 1.2, rate: 0.9, volume: 0.78, pause: 0.14)
        default:
            return VoiceStyle(pitch: 1.28, rate: 0.94, volume: 0.86, pause: 0.12)
        }
    }
}

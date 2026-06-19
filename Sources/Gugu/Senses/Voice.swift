import AVFoundation
import GuguKernel
import AppKit

/// 本地语音合成(TTS)。用 AVSpeechSynthesizer,完全本地、零 token、零网络。
/// 轻微提高音调并按情绪调节语速,保留角色感但避免系统提示音般尖硬。
@MainActor
final class Voice: NSObject {
    private let synth = AVSpeechSynthesizer()
    private var chineseVoice: AVSpeechSynthesisVoice?
    private var englishVoice: AVSpeechSynthesisVoice?
    var onWillSpeak: ((String) -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.voice.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.voice.enabled")
              if !newValue { synth.stopSpeaking(at: .immediate) } }
    }

    override init() {
        super.init()
        // 在所有中文嗓里挑"最不机械"的一个(打分排序),没有高质量嗓时给出下载提示。
        let all = AVSpeechSynthesisVoice.speechVoices()
        chineseVoice = all.filter { $0.language.hasPrefix("zh") }
            .max { Voice.naturalness($0, preferred: "zh-CN") < Voice.naturalness($1, preferred: "zh-CN") }
        englishVoice = all.filter { $0.language.hasPrefix("en") }
            .max { Voice.naturalness($0, preferred: "en-US") < Voice.naturalness($1, preferred: "en-US") }

        if let v = chineseVoice {
            Log.info("voice", "选用嗓音:\(v.name)(\(v.language)/\(Voice.qualityName(v.quality)))")
            if v.quality == .default {
                // 系统里没有增强版/高级版中文嗓,compact/eloquence 都偏机械。提示用户下载。
                Log.info("voice", "未发现增强版中文嗓,声音偏机械。可在「系统设置→辅助功能→朗读内容→系统嗓音→管理嗓音」下载中文(中国)的增强版/高级版嗓音,咕咕会自动启用。")
            }
        } else {
            Log.info("voice", "未找到任何中文嗓,将使用系统默认嗓。")
        }
        if let v = englishVoice {
            Log.info("voice", "English voice: \(v.name) (\(v.language)/\(Voice.qualityName(v.quality)))")
        }
    }

    /// 给嗓音打分,分高者更自然。核心:高质量(增强/高级)优先;玩具嗓/Eloquence 重罚;
    /// 同等条件下偏好首选语言变体,并避开保真度最低的 super-compact。
    static func naturalness(_ v: AVSpeechSynthesisVoice, preferred: String) -> Int {
        var score = v.quality.rawValue * 1000   // default=1, enhanced=2, premium=3
        let id = v.identifier
        // 老式趣味嗓(Albert 沙哑、Whisper 气声、Bad News、Zarvox…)前缀都是这个。
        // 它们和正经嗓同为 default 质量却不被任何条款扣分,会盖过 Samantha,务必重罚到任何正经嗓之下。
        if id.hasPrefix("com.apple.speech.synthesis.voice.") { score -= 5000 }
        if id.contains("eloquence") { score -= 500 }       // DECtalk 风格,最生硬
        if id.contains("super-compact") { score -= 50 }    // 保真度最低
        let prefix = String(preferred.prefix(2))
        if v.language == preferred { score += 100 }
        else if v.language.hasPrefix(prefix) { score += 10 }
        return score
    }

    private static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "高级版"
        case .enhanced: return "增强版"
        default: return "标准"
        }
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
        // 按文本本身选嗓音:含中日韩字符走中文嗓,否则走英文嗓。
        let voice = Voice.containsCJK(text) ? chineseVoice : (englishVoice ?? chineseVoice)
        for (index, sentence) in Voice.splitSentences(text).enumerated() {
            let u = AVSpeechUtterance(string: sentence)
            u.voice = voice
            u.pitchMultiplier = style.pitch
            u.rate = AVSpeechUtteranceDefaultSpeechRate * style.rate
            u.volume = style.volume
            u.preUtteranceDelay = index == 0 ? 0 : style.pause
            u.postUtteranceDelay = style.pause * 0.4
            synth.speak(u)
        }
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// 文本里是否含中日韩字符——据此选中文嗓还是英文嗓。
    static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3400...0x4DBF,   // CJK Extension A
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul
                return true
            default:
                continue
            }
        }
        return false
    }

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
        // English: break on word boundaries so we don't cut words mid-syllable.
        if !containsCJK(trimmed), trimmed.contains(" ") {
            var line = ""
            for word in trimmed.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= maxChars {
                    line += " " + word
                } else {
                    pieces.append(line)
                    line = String(word)
                }
            }
            if !line.isEmpty { pieces.append(line) }
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

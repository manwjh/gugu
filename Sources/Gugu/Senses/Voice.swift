import AVFoundation
import AppKit

/// 本地语音合成(TTS)。用 AVSpeechSynthesizer,完全本地、零 token、零网络。
/// 捏高音调 + 略快语速,合成出小鸟般尖细的嗓音。默认关,菜单栏开。
@MainActor
final class Voice: NSObject {
    private let synth = AVSpeechSynthesizer()
    private var chineseVoice: AVSpeechSynthesisVoice?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gugu.voice.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gugu.voice.enabled")
              if !newValue { synth.stopSpeaking(at: .immediate) } }
    }

    override init() {
        super.init()
        // 选一个中文嗓(优先增强版),没有就用系统默认
        let voices = AVSpeechSynthesisVoice.speechVoices()
        chineseVoice = voices.first { $0.language.hasPrefix("zh") && $0.quality == .enhanced }
            ?? voices.first { $0.language.hasPrefix("zh") }
    }

    /// 说一句话。会先把括号里的舞台提示(如"歪头看了看你")去掉,只念真正说出口的字。
    func speak(_ raw: String) {
        guard enabled else { return }
        let text = Voice.stripStageDirections(raw)
        guard !text.isEmpty else { return }
        // 抢断上一句,保证回应及时
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = chineseVoice
        u.pitchMultiplier = 1.6     // 0.5–2.0:拉高成小鸟嗓
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        u.volume = 0.9
        synth.speak(u)
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
}

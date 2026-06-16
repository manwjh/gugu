import Foundation

/// Local emotion scalars. Zero-cost, real-time, never touch the LLM directly;
/// they drive L0 presentation and one line of the heartbeat prompt.
///
/// Bond is the one long-term scalar; it lives in PetState (state.json) as the
/// single source of truth, not here. Affect only emits the small per-interaction
/// increments via `bondGain*`, and the caller persists them to PetState.
@MainActor
final class Affect {
    /// 0…1, circadian + interaction cost
    private(set) var energy: Double = 0.8
    /// -1…1 event-driven mood
    private(set) var valence: Double = 0.2
    /// 0…1 tension
    private(set) var arousal: Double = 0.1

    /// Per-interaction bond increments, owned by PetState (see class note).
    static let bondGainPetted = 0.002
    static let bondGainChatted = 0.005

    /// Grudge: valence locked low until this date (e.g. after being thrown).
    private var grudgeUntil: Date?

    func tickMinute() {
        // circadian energy: high mid-day, low at night
        let hour = Double(Calendar.current.component(.hour, from: Date()))
        let minute = Double(Calendar.current.component(.minute, from: Date()))
        let h = hour + minute / 60
        let circadian = 0.5 + 0.45 * sin((h - 8) / 24 * 2 * .pi) // peaks ~14:00
        energy += (circadian - energy) * 0.08
        // mood decays toward mild positive baseline
        if grudgeUntil == nil || Date() > grudgeUntil! {
            grudgeUntil = nil
            valence += (0.15 - valence) * 0.05
        }
        arousal *= 0.9
    }

    func petted()  { valence = min(1, valence + 0.25)
                     if let g = grudgeUntil, Date() < g { grudgeUntil = Date().addingTimeInterval(-1) } } // 摸两下就和好
    func poked()   { arousal = min(1, arousal + 0.2); valence = min(1, valence + 0.05) }
    func thrown()  { valence = -0.6; arousal = 0.8; grudgeUntil = Date().addingTimeInterval(1800) }  // 记仇30分钟
    func ownerReturned() { valence = min(1, valence + 0.3) }
    func chatted() { valence = min(1, valence + 0.1) }

    var isGrudging: Bool { grudgeUntil.map { Date() < $0 } ?? false }
    var isSleepyTime: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 2 && h < 7
    }

    /// One line for the heartbeat prompt, in the pet's own voice context.
    func promptLine() -> String {
        var parts: [String] = []
        if energy < 0.3 { parts.append("你有点困") }
        if isGrudging { parts.append("你刚被摔了,还在委屈") }
        else if valence > 0.5 { parts.append("你心情很好") }
        else if valence < -0.2 { parts.append("你心情不太好") }
        if arousal > 0.6 { parts.append("你有点紧张") }
        return parts.isEmpty ? "你状态平平,普普通通的一天" : parts.joined(separator: ";")
    }
}

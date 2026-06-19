import Foundation

/// Work-rhythm states derived from keyboard/mouse cadence.
/// Privacy invariant: we only sample *whether* input happened recently via
/// CGEventSource.secondsSinceLastEventType — no event tap, no keycodes,
/// no coordinates, no content. Nothing here requires Accessibility permission.
///
/// Foundational value type: lives in Kernel so both the producer (RhythmSensor
/// in Senses) and consumers (Memory.activeSkills, prompt builders) depend down
/// on it rather than on each other.
enum WorkRhythm: String {
    case focused = "专注工作"     // sustained keyboard activity
    case busy = "忙碌操作"        // mixed dense input
    case breather = "歇口气"      // input stopped 3–5 min, mouse twitches
    case away = "离开"            // no input > 10 min
    case active = "随便用用"      // light activity
    case agitated = "可能烦躁"    // mouse thrash heuristics

    /// Localized name for UI display. rawValue stays Chinese (used in LLM prompts).
    @MainActor var displayName: String {
        switch self {
        case .focused: return L.rhythmFocused
        case .busy: return L.rhythmBusy
        case .breather: return L.rhythmBreather
        case .away: return L.rhythmAway
        case .active: return L.rhythmActive
        case .agitated: return L.rhythmAgitated
        }
    }
}

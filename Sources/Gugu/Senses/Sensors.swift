import Foundation
import GuguKernel
import CoreGraphics
import AppKit

// `WorkRhythm` (the rhythm-state enum) now lives in Kernel/WorkRhythm.swift so
// that Memory and prompt builders depend down on it instead of up into Senses.

/// Samples input recency once per second; aggregates into per-minute counts;
/// derives a rhythm state. Reports transitions to the EventBus.
@MainActor
final class RhythmSensor {
    private(set) var rhythm: WorkRhythm = .active
    private(set) var keyMinuteCounts: [Int] = []     // active-seconds per minute (keyboard)
    private(set) var mouseMinuteCounts: [Int] = []   // active-seconds per minute (mouse)
    private var keyActiveSeconds = 0
    private var mouseActiveSeconds = 0
    private var secondTick = 0
    private var lastInputAt = Date()
    private var sessionStart: Date?                  // start of current focused streak
    private var timer: Timer?
    var onRhythmChange: ((WorkRhythm, WorkRhythm) -> Void)?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let kbd = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mmv = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        )
        if kbd < 1.0 { keyActiveSeconds += 1; lastInputAt = Date() }
        if mmv < 1.0 { mouseActiveSeconds += 1; lastInputAt = Date() }

        secondTick += 1
        if secondTick >= 60 {
            keyMinuteCounts.append(keyActiveSeconds)
            mouseMinuteCounts.append(mouseActiveSeconds)
            if keyMinuteCounts.count > 120 { keyMinuteCounts.removeFirst(); mouseMinuteCounts.removeFirst() }
            keyActiveSeconds = 0; mouseActiveSeconds = 0; secondTick = 0
            reclassify()
        }
    }

    /// Idle seconds right now (cheap, used by scheduler too).
    var idleSeconds: TimeInterval {
        max(0, Date().timeIntervalSince(lastInputAt))
    }

    private func reclassify() {
        let lastKeys = keyMinuteCounts.suffix(3)
        let lastMouse = mouseMinuteCounts.suffix(3)
        let keyAvg = lastKeys.isEmpty ? 0 : Double(lastKeys.reduce(0,+)) / Double(lastKeys.count)
        let mouseAvg = lastMouse.isEmpty ? 0 : Double(lastMouse.reduce(0,+)) / Double(lastMouse.count)
        let idle = idleSeconds

        let new: WorkRhythm
        if idle > 600 {
            new = .away
        } else if idle > 150 && idle < 360 {
            new = .breather
        } else if keyAvg >= 20 && mouseAvg < keyAvg {
            new = .focused
        } else if keyAvg >= 10 && mouseAvg >= 10 {
            new = .busy
        } else if mouseAvg >= 35 && keyAvg < 5 {
            new = .agitated
        } else {
            new = .active
        }

        if new != rhythm {
            let old = rhythm
            rhythm = new
            handleTransition(from: old, to: new)
            onRhythmChange?(old, new)
        }

        // overtime detection: focused/busy after 23:00
        let hour = Calendar.current.component(.hour, from: Date())
        if (new == .focused || new == .busy), hour >= 23 || hour < 5 {
            if sessionStart == nil { sessionStart = Date() }
            if let s = sessionStart, Date().timeIntervalSince(s) > 1800 {
                EventBus.shared.post(kind: "overtime", summary: "主人深夜(\(hour)点)还在高强度工作", weight: 40)
                sessionStart = Date()  // don't repeat every minute
            }
        } else if new != .focused && new != .busy {
            sessionStart = nil
        }
    }

    private func handleTransition(from old: WorkRhythm, to new: WorkRhythm) {
        switch (old, new) {
        case (_, .breather) where old == .focused || old == .busy:
            let streak = focusedStreakDescription()
            EventBus.shared.post(kind: "rhythm", summary: "主人刚停下来歇口气\(streak)", weight: 35)
        case (.away, _) where new != .away:
            EventBus.shared.post(kind: "return", summary: "主人回来了", weight: 30)
        case (_, .away):
            EventBus.shared.post(kind: "leave", summary: "主人离开了", weight: 5)
        case (_, .agitated):
            EventBus.shared.post(kind: "rhythm", summary: "主人的鼠标动得很急,可能有点烦躁", weight: 15)
        default:
            break
        }
    }

    /// "(之前高强度敲了约 N 分钟)" if we can see a streak in the minute counts.
    private func focusedStreakDescription() -> String {
        var n = 0
        for v in keyMinuteCounts.reversed() {
            if v >= 15 { n += 1 } else { break }
        }
        return n >= 5 ? "(之前高强度敲了约\(n)分钟)" : ""
    }

    /// One line for the heartbeat prompt.
    func promptLine() -> String {
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        return "当前节奏:\(rhythm.rawValue);现在 \(df.string(from: Date()))"
    }
}

/// Frontmost-app sensor (no permission needed). Posts app-switch events,
/// suppressed for blacklisted apps.
@MainActor
final class ScreenSensor {
    private var lastApp = ""
    private var lastSwitch = Date()
    private var blacklist: [String]
    private(set) var currentApp = ""
    private(set) var blacklisted = false

    init(blacklist: [String]) { self.blacklist = blacklist }

    func updateBlacklist(_ blacklist: [String]) {
        self.blacklist = blacklist
        blacklisted = isBlacklisted(currentApp)
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            Task { @MainActor in self?.appChanged(to: name) }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
            currentApp = front
            lastApp = front
            blacklisted = isBlacklisted(front)
        }
    }

    private func appChanged(to name: String) {
        guard name != lastApp else { return }
        let dwellMin = Int(Date().timeIntervalSince(lastSwitch) / 60)
        blacklisted = isBlacklisted(name)
        currentApp = name
        if !blacklisted {
            let dwell = dwellMin >= 2 ? "(在上一个用了\(dwellMin)分钟)" : ""
            EventBus.shared.post(kind: "app_switch", summary: "主人切到了 \(name)\(dwell)", weight: 8)
        }
        lastApp = name
        lastSwitch = Date()
    }

    func promptLine() -> String {
        blacklisted ? "前台:(咕咕没在看)" : "前台 App:\(currentApp)"
    }

    private func isBlacklisted(_ appName: String) -> Bool {
        guard !appName.isEmpty else { return false }
        return blacklist.contains { appName.localizedCaseInsensitiveContains($0) }
    }
}

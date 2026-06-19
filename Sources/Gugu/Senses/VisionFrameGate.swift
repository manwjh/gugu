import Foundation

final class VisionFrameGate: @unchecked Sendable {
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

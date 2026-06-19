import Foundation

@MainActor
final class VideoUnderstandingTracker {
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

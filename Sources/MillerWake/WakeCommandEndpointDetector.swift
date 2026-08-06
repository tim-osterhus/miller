// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Foundation

struct WakeCommandEndpointDetector: Sendable {
    static let frameDuration = 0.03

    private(set) var speechStarted = false
    private var recentSpeech = [Bool]()
    private var silenceSeconds = 0.0
    private var elapsedSeconds = 0.0
    private(set) var nonFiniteDBFSCount = 0
    let thresholdDBFS: Double

    init(ambientDBFS: Double? = nil) {
        let ambient = ambientDBFS?.isFinite == true ? ambientDBFS! : -60
        thresholdDBFS = min(max(ambient + 10, -50), -28)
    }

    mutating func process(dbfs: Double) -> WakeCommandEndpointEvent {
        elapsedSeconds += Self.frameDuration
        if elapsedSeconds >= 30 {
            return .hardLimit
        }

        if !dbfs.isFinite {
            nonFiniteDBFSCount += 1
        }
        let isSpeech = dbfs.isFinite && dbfs > thresholdDBFS

        if !speechStarted {
            recentSpeech.append(isSpeech)
            if recentSpeech.count > 5 {
                recentSpeech.removeFirst()
            }
            if recentSpeech.count == 5,
               recentSpeech.filter({ $0 }).count >= 3 {
                speechStarted = true
            }
            return elapsedSeconds >= 4 ? .emptyWakeTimeout : .continueListening
        }

        silenceSeconds = isSpeech ? 0 : silenceSeconds + Self.frameDuration
        return silenceSeconds >= 1.5 ? .silence : .continueListening
    }

    mutating func reset() {
        speechStarted = false
        recentSpeech.removeAll(keepingCapacity: false)
        silenceSeconds = 0
        elapsedSeconds = 0
        nonFiniteDBFSCount = 0
    }
}

struct WakeCommandAmbientSampler: Sendable {
    private(set) var observedDuration = 0.0
    private(set) var nonFiniteDBFSCount = 0
    private var frames = [(dbfs: Double, duration: Double)]()

    mutating func observe(dbfs: Double) {
        let duration = WakeCommandEndpointDetector.frameDuration
        if !dbfs.isFinite {
            nonFiniteDBFSCount += 1
        }

        frames.append((dbfs, duration))
        observedDuration += duration
        while let oldest = frames.first,
              observedDuration - oldest.duration >= 2 {
            frames.removeFirst()
            observedDuration -= oldest.duration
        }
    }

    var medianOrFallback: Double {
        let finiteValues = frames.compactMap { frame in
            frame.dbfs.isFinite ? frame.dbfs : nil
        }
        guard observedDuration >= 2, !finiteValues.isEmpty else {
            return -60
        }

        let ordered = finiteValues.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    mutating func reset() {
        observedDuration = 0
        nonFiniteDBFSCount = 0
        frames.removeAll(keepingCapacity: false)
    }
}

enum WakeWordFrameAudio {
    static let requiredFrameLength = 480

    static func dbfs(_ frame: ContiguousArray<Int16>) -> Double {
        guard frame.count == requiredFrameLength else {
            return -.infinity
        }

        let meanSquare = frame.reduce(0.0) { partial, sample in
            let normalized = Double(sample) / 32_768.0
            return partial + (normalized * normalized)
        } / Double(requiredFrameLength)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -.infinity
    }
}

struct WakeWordCommandBuffer: Sendable {
    let sampleRate: Int
    let maximumDuration: TimeInterval
    private(set) var samples = ContiguousArray<Int16>()

    init(sampleRate: Int = 16_000, maximumDuration: TimeInterval = 2) {
        precondition(sampleRate > 0)
        precondition(maximumDuration > 0)
        self.sampleRate = sampleRate
        self.maximumDuration = maximumDuration
    }

    var capacity: Int {
        Int(Double(sampleRate) * maximumDuration)
    }

    mutating func append(_ incoming: some Collection<Int16>) {
        let remaining = capacity - samples.count
        guard remaining > 0 else { return }
        samples.append(contentsOf: incoming.prefix(remaining))
    }

    mutating func take() -> ContiguousArray<Int16> {
        let result = samples
        samples.removeAll(keepingCapacity: false)
        return result
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
    }
}

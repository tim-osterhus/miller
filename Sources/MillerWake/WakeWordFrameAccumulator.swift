// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
struct WakeWordFrameAccumulator: Sendable {
    private(set) var tail = ContiguousArray<Int16>()
    let frameLength: Int

    init(frameLength: Int = 480) {
        precondition(frameLength > 0)
        self.frameLength = frameLength
    }

    mutating func append(
        _ samples: some Collection<Int16>
    ) -> [ContiguousArray<Int16>] {
        tail.append(contentsOf: samples)

        var frames = [ContiguousArray<Int16>]()
        while tail.count >= frameLength {
            frames.append(ContiguousArray(tail.prefix(frameLength)))
            tail.removeFirst(frameLength)
        }
        return frames
    }

    mutating func reset() {
        tail.removeAll(keepingCapacity: false)
    }
}

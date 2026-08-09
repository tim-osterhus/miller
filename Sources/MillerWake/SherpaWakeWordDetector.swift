// Adapted from owner-authored Cortana wakeword source at commit
// 8f4af867c575c089f45a8df4768663a521f88203.
import Foundation
import MillerWakeBridge

public struct SherpaWakeWordTuning: Equatable, Sendable {
    nonisolated static let defaultKeywordScore = 5.0
    nonisolated static let defaultKeywordThreshold = 0.05

    public let keywordScore: Double
    public let keywordThreshold: Double

    public init?(keywordScore: Double, keywordThreshold: Double) {
        let nativeScore = Float(keywordScore)
        guard nativeScore.isFinite,
              nativeScore > 0,
              keywordThreshold.isFinite,
              (0...1).contains(keywordThreshold) else {
            return nil
        }
        self.keywordScore = keywordScore
        self.keywordThreshold = keywordThreshold
    }

    public nonisolated static let `default` = SherpaWakeWordTuning(
        keywordScore: defaultKeywordScore,
        keywordThreshold: defaultKeywordThreshold
    )!

}

/// Swift-owned operations for the pinned Sherpa C bridge. Production
/// composition supplies live operations; tests inject a fake table.
struct SherpaWakeWordRuntime: @unchecked Sendable {
    let create:
        @Sendable (WakeWordModelPaths, SherpaWakeWordTuning) -> OpaquePointer?
    let accept: @Sendable (OpaquePointer, UnsafePointer<Float>, Int32) -> Int32
    let reset: @Sendable (OpaquePointer) -> Void
    let destroy: @Sendable (OpaquePointer?) -> Void

    static let live = SherpaWakeWordRuntime(
        create: { paths, tuning in
            paths.encoder.path.withCString { encoder in
                paths.decoder.path.withCString { decoder in
                    paths.joiner.path.withCString { joiner in
                        paths.tokens.path.withCString { tokens in
                            paths.keywords.path.withCString { keywords in
                                MWWSherpaCreate(
                                    encoder,
                                    decoder,
                                    joiner,
                                    tokens,
                                    keywords,
                                    Float(tuning.keywordScore),
                                    Float(tuning.keywordThreshold)
                                )
                            }
                        }
                    }
                }
            }
        },
        accept: { handle, samples, count in
            MWWSherpaAccept(handle, samples, count)
        },
        reset: { handle in MWWSherpaReset(handle) },
        destroy: { handle in MWWSherpaDestroy(handle) }
    )
}

public final class SherpaWakeWordDetector: WakeWordDetecting, @unchecked Sendable {
    public let requiredSampleRate = 16_000
    public let requiredFrameLength = 480

    private let runtime: SherpaWakeWordRuntime
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public var status: WakeWordDetectorStatus {
        lock.withLock { handle == nil ? .shutDown : .ready }
    }

    public convenience init(
        paths: WakeWordModelPaths,
        tuning: SherpaWakeWordTuning = .default
    ) throws {
        try self.init(paths: paths, tuning: tuning, runtime: .live)
    }

    init(
        paths: WakeWordModelPaths,
        tuning: SherpaWakeWordTuning = .default,
        runtime: SherpaWakeWordRuntime = .live
    ) throws {
        self.runtime = runtime
        handle = runtime.create(paths, tuning)
        guard handle != nil else {
            throw WakeWordDetectorError.unavailable
        }
    }

    public func process(frame: ContiguousArray<Int16>) throws -> Bool {
        guard frame.count == requiredFrameLength else {
            throw WakeWordDetectorError.invalidFrame
        }

        return try lock.withLock {
            guard let handle else {
                throw WakeWordDetectorError.unavailable
            }

            let normalized = frame.map { Float($0) / 32_768.0 }
            let result = normalized.withUnsafeBufferPointer { samples in
                runtime.accept(handle, samples.baseAddress!, Int32(samples.count))
            }

            switch result {
            case 0:
                return false
            case 1:
                return true
            default:
                throw WakeWordDetectorError.runtimeFailure
            }
        }
    }

    public func reset() throws {
        try lock.withLock {
            guard let handle else {
                throw WakeWordDetectorError.unavailable
            }
            runtime.reset(handle)
        }
    }

    public func shutdown() {
        lock.withLock {
            guard let activeHandle = handle else { return }
            handle = nil
            runtime.destroy(activeHandle)
        }
    }

    deinit {
        shutdown()
    }
}

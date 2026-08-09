import Foundation

enum MicrophoneOwner: Equatable, Sendable {
    case wake
    case live
}

enum MicrophoneOwnershipError: Error, Equatable, Sendable {
    case busy
}

/// Process-local exclusion for the two microphone authorities Miller owns.
/// The lease is synchronous so a capture teardown can release it before the
/// next AVAudioEngine/WebKit owner starts.
final class MicrophoneOwnership: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private let releaseOperation: @Sendable () -> Void

        init(release: @escaping @Sendable () -> Void) {
            releaseOperation = release
        }

        func release() {
            let shouldRelease = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            if shouldRelease { releaseOperation() }
        }

        deinit { release() }
    }

    private let lock = NSLock()
    private var owner: MicrophoneOwner?

    func acquire(_ requestedOwner: MicrophoneOwner) throws -> Lease {
        try lock.withLock {
            guard owner == nil else { throw MicrophoneOwnershipError.busy }
            owner = requestedOwner
            return Lease { [weak self] in self?.release(requestedOwner) }
        }
    }

    private func release(_ releasedOwner: MicrophoneOwner) {
        lock.withLock {
            guard owner == releasedOwner else { return }
            owner = nil
        }
    }
}

struct FollowTailState: Equatable {
    static let bottomTolerance = 24.0

    private(set) var isFollowing = true

    mutating func userScrolled(distanceFromBottom: Double) {
        isFollowing = distanceFromBottom <= Self.bottomTolerance
    }

    mutating func jumpToLatest() {
        isFollowing = true
    }

    mutating func conversationReplaced() {
        isFollowing = true
    }

    func shouldFollowContentChange() -> Bool {
        isFollowing
    }

    func shouldAnimateScroll(reduceMotion: Bool) -> Bool {
        isFollowing && !reduceMotion
    }
}

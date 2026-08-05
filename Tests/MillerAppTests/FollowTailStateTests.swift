import Testing
@testable import MillerApp

@Suite
struct FollowTailStateTests {
    @Test
    func beginsFollowing() {
        #expect(FollowTailState().isFollowing)
    }

    @Test
    func streamingAtBottomContinuesFollowing() {
        let state = FollowTailState()

        #expect(state.shouldFollowContentChange())
    }

    @Test
    func manualUpwardScrollSuspendsFollowing() {
        var state = FollowTailState()

        state.userScrolled(distanceFromBottom: 25)

        #expect(!state.isFollowing)
    }

    @Test
    func continuedStreamingDoesNotResumeSuspendedFollowing() {
        var state = FollowTailState()
        state.userScrolled(distanceFromBottom: 25)

        #expect(!state.shouldFollowContentChange())
        #expect(!state.isFollowing)
    }

    @Test(arguments: [0.0, 23.999, 24.0])
    func returningWithinBottomToleranceResumesFollowing(
        distanceFromBottom: Double
    ) {
        var state = FollowTailState()
        state.userScrolled(distanceFromBottom: 25)

        state.userScrolled(distanceFromBottom: distanceFromBottom)

        #expect(state.isFollowing)
    }

    @Test
    func jumpToLatestResumesFollowing() {
        var state = FollowTailState()
        state.userScrolled(distanceFromBottom: 25)

        state.jumpToLatest()

        #expect(state.isFollowing)
    }

    @Test
    func conversationReplacementResumesFollowing() {
        var state = FollowTailState()
        state.userScrolled(distanceFromBottom: 25)

        state.conversationReplaced()

        #expect(state.isFollowing)
    }

    @Test
    func reducedMotionDisablesScrollAnimation() {
        let state = FollowTailState()

        #expect(state.shouldAnimateScroll(reduceMotion: false))
        #expect(!state.shouldAnimateScroll(reduceMotion: true))
    }
}

import Foundation
import Testing
@testable import AppFeature

struct RadioPlaybackRecoveryTests {
    @Test func firstPlaybackDistinguishesConnectingBufferingAndFailure() {
        var state = RadioPlaybackRecovery()
        #expect(state.phase == .connecting)
        state.observe(.buffering, allowsRetry: true)
        #expect(state.phase == .buffering)
        state.observe(.failed, allowsRetry: true)
        #expect(state.phase == .failed)
        #expect(state.hasFailed)
        #expect(state.retry.attempts == 0)
    }

    @Test func spontaneousRecoveryRestoresPlaybackWithoutSpendingAnAttempt() {
        var state = RadioPlaybackRecovery()
        state.observe(.playing, allowsRetry: true)
        #expect(state.phase == .playing)
        state.observe(.buffering, allowsRetry: true)
        #expect(state.phase == .waitingToRetry(attempt: 1, total: 3))
        state.observe(.playing, allowsRetry: true)
        #expect(state.phase == .recovered)
        state.observe(.playing, allowsRetry: true)
        #expect(state.phase == .recovered)
        #expect(state.retry.attempts == 0)
    }

    @Test func attemptsTrackBackoffAndTerminalFailure() {
        var state = RadioPlaybackRecovery()
        state.observe(.playing, allowsRetry: true)
        for attempt in 1...3 {
            state.observe(.buffering, allowsRetry: true)
            #expect(state.phase == .waitingToRetry(attempt: attempt, total: 3))
            state.beginAttempt()
            #expect(state.phase == .reconnecting(attempt: attempt, total: 3))
            state.observe(.connecting, allowsRetry: true)
            if attempt < 3 {
                #expect(state.phase == .waitingToRetry(attempt: attempt + 1, total: 3))
                state.observe(.interrupted, allowsRetry: true)
                #expect(state.phase == .interrupted)
                #expect(state.phase.canRetry)
            } else {
                #expect(state.phase == .reconnecting(attempt: 3, total: 3))
            }
        }
        state.observe(.failed, allowsRetry: true)
        #expect(state.phase == .recoveryFailed)
        #expect(state.hasFailed)
    }

    @Test func lastAttemptCanRecoverAfterAutomaticRetriesEnd() {
        var state = RadioPlaybackRecovery()
        state.observe(.playing, allowsRetry: true)
        for _ in 1...3 {
            state.observe(.buffering, allowsRetry: true)
            state.beginAttempt()
        }
        state.finishWaitingForFinalResult()
        #expect(state.phase == .recoveryFailed)
        #expect(state.phase.canRetry)
        #expect(!state.hasFailed)

        state.observe(.buffering, allowsRetry: true)
        #expect(state.phase == .recoveryFailed)
        state.observe(.playing, allowsRetry: true)
        #expect(state.phase == .recovered)
        #expect(state.retry.attempts == 0)
    }

    @Test func recoveryCanResumeWithoutAutomaticRetries() {
        var state = RadioPlaybackRecovery()
        state.observe(.playing, allowsRetry: false)
        state.observe(.buffering, allowsRetry: false)
        #expect(state.phase == .interrupted)
        #expect(state.phase.canRetry)
        state.observe(.playing, allowsRetry: false)
        #expect(state.phase == .recovered)
    }

    @Test func aSessionIgnoresLateAndUnscopedEvents() throws {
        let current = UUID()
        let station = UUID()
        var session = RadioPlaybackSession(id: current, stationID: station, streamURL: "https://example.com", phase: .paused)

        let stale = PlaybackHelperEvent(radioPhase: .failed, playbackID: UUID())
        let acceptedStale = session.receive(stale)
        let acceptedUnscoped = session.receive(.init(radioPhase: .recovered))
        #expect(!acceptedStale)
        #expect(!acceptedUnscoped)
        #expect(session.phase == .paused)
        let start = PlaybackHelperEvent(radioPhase: .reconnecting(attempt: 2, total: 3), playbackID: current)
        let decoded = try JSONDecoder().decode(PlaybackHelperEvent.self, from: JSONEncoder().encode(start))
        let acceptedCurrent = session.receive(decoded)
        #expect(acceptedCurrent)
        #expect(session.phase == .reconnecting(attempt: 2, total: 3))
        let changedURL = RadioPlayerItem(streamUrl: "https://different.example.com", id: station)
        #expect(!session.matches(changedURL))
    }
}

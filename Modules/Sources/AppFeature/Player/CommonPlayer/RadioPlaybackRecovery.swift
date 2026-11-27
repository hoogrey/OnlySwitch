import RadioBrowser

/// Maps observations from the current audible backend to a display phase.
struct RadioPlaybackRecovery {
    enum Observation {
        case connecting, buffering, playing, interrupted, failed
    }

    private(set) var phase: RadioPlaybackPhase = .connecting
    private(set) var retry = RadioReconnect()
    private(set) var hasPlayed = false

    /// True once recovery has used every retry, even if the last player can still recover.
    var awaitsFinalResult: Bool {
        if case let .reconnecting(attempt, total) = phase { return attempt == total }
        return false
    }

    var hasFailed: Bool {
        phase == .failed || (phase == .recoveryFailed && !finalWaitExpired)
    }

    private var finalWaitExpired = false

    mutating func observe(_ observation: Observation, allowsRetry: Bool) {
        switch observation {
        case .playing:
            if phase != .recovered {
                phase = hasPlayed && phase != .playing ? .recovered : .playing
            }
            hasPlayed = true
            finalWaitExpired = false
            retry.reset()
        case .failed:
            finalWaitExpired = false
            if allowsRetry, hasPlayed {
                phase = retry.delay == nil ? .recoveryFailed : nextRetry
            } else {
                phase = .failed
            }
        case .connecting, .buffering, .interrupted:
            if finalWaitExpired { return }
            if allowsRetry, hasPlayed {
                if retry.delay != nil {
                    // Waiting items queue the next backoff even before they become ready.
                    // An unexpectedly paused item has no scheduled reconnection.
                    phase = observation == .interrupted ? .interrupted : nextRetry
                }
            } else if hasPlayed || observation == .interrupted {
                phase = .interrupted
            } else {
                phase = observation == .connecting ? .connecting : .buffering
            }
        }
    }

    mutating func beginAttempt() {
        retry.recordAttempt()
        phase = .reconnecting(attempt: retry.attempts, total: RadioReconnect.totalAttempts)
    }

    mutating func finishWaitingForFinalResult() {
        guard awaitsFinalResult else { return }
        finalWaitExpired = true
        phase = .recoveryFailed
    }

    private var nextRetry: RadioPlaybackPhase {
        .waitingToRetry(attempt: retry.attempts + 1, total: RadioReconnect.totalAttempts)
    }
}

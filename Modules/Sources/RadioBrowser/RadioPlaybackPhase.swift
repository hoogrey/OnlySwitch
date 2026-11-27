/// An observed Radio playback phase. Playback intent is tracked separately so playback
/// can still be stopped while the player is connecting or recovering.
public enum RadioPlaybackPhase: Codable, Equatable, Sendable {
    case idle
    case connecting
    case buffering
    case playing
    case paused
    case interrupted
    case waitingToRetry(attempt: Int, total: Int)
    case reconnecting(attempt: Int, total: Int)
    case recovered
    case failed
    case recoveryFailed

    public var canRetry: Bool {
        switch self {
        case .interrupted, .failed, .recoveryFailed: true
        default: false
        }
    }
}

import Dependencies
import Foundation

struct RadioStationNotificationIdentity: Equatable, Sendable {
    let id: UUID
    let streamURL: String
}

/// Tracks playback requests independently of title edits and pause/retry cycles.
@MainActor
final class RadioNotificationCoordinator {
    private let client: RadioNotificationClient
    private var lastStation: RadioStationNotificationIdentity?

    init(client: RadioNotificationClient? = nil) {
        @Dependency(\.radioNotification) var notification
        self.client = client ?? notification
    }

    @discardableResult
    func playbackStarted(identity: RadioStationNotificationIdentity, title: String,
                         enabled: Bool) -> Task<Bool, Never>? {
        guard identity != lastStation else { return nil }
        lastStation = identity
        guard enabled, !title.isEmpty else { return nil }
        let notification = RadioNotification.nowPlaying(station: title)
        return client.enqueue(notification)
    }
}

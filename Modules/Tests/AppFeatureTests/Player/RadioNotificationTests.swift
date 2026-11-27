import Foundation
import Testing
@testable import AppFeature

@MainActor
struct RadioNotificationTests {
    @Test func stoppedStationUpdateNotifiesAtPlaybackStart() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        var item = RadioPlayerItem(title: "Original", streamUrl: "https://example.com/a", id: UUID())
        await start(item, using: coordinator)

        // Favorites pause before assigning the complete destination station.
        item.isPlaying = false
        item.title = "Destination"
        item.id = UUID()
        item.streamUrl = "https://example.com/b"
        #expect(await recorder.notifications.count == 1)
        item.isPlaying = true
        await start(item, using: coordinator)

        #expect(await recorder.notifications.map(\.body) == ["Original", "Destination"])
    }

    @Test func resumeRepeatAndRetryRetainStationIdentity() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        let item = RadioPlayerItem(title: "Station", streamUrl: "https://example.com/a", id: UUID())
        for _ in 0..<4 { await start(item, using: coordinator) }
        #expect(await recorder.notifications.count == 1)
    }

    @Test func stationDeliveryPreservesOrderAcrossSuspendedAuthorization() async throws {
        let gate = AuthorizationGate()
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: RadioNotificationClient(
            requestAuthorization: { await gate.authorize() },
            deliver: { try await recorder.client.deliver($0) }
        ))
        let first = try #require(coordinator.playbackStarted(
            identity: .init(id: UUID(), streamURL: "https://example.com/a"),
            title: "A", enabled: true
        ))
        await gate.waitUntilRequested()
        let second = try #require(coordinator.playbackStarted(
            identity: .init(id: UUID(), streamURL: "https://example.com/b"),
            title: "B", enabled: true
        ))
        await gate.release()
        await first.value
        await second.value
        #expect(await recorder.notifications.map(\.body) == ["A", "B"])
    }

    @Test func trackAndStationShareOrderAcrossSuspendedAuthorization() async throws {
        let gate = AuthorizationGate()
        let recorder = Recorder()
        let client = RadioNotificationClient(
            requestAuthorization: { await gate.authorize() },
            deliver: { try await recorder.client.deliver($0) }
        )
        let coordinator = RadioNotificationCoordinator(client: client)
        let oldTrack = try #require(client.trackChanged(
            station: "A", previousTrack: "Previous", track: "A track",
            isPlaying: true, enabled: true
        ))
        await gate.waitUntilRequested()
        let newStation = try #require(coordinator.playbackStarted(
            identity: .init(id: UUID(), streamURL: "https://example.com/b"),
            title: "B", enabled: true
        ))
        let newTrack = try #require(client.trackChanged(
            station: "B", previousTrack: "", track: "B track",
            isPlaying: true, enabled: true
        ))
        #expect(await gate.authorizationRequests == 1)
        #expect(await recorder.notifications.isEmpty)
        await gate.release()
        await oldTrack.value
        await newStation.value
        await newTrack.value
        let notifications = await recorder.notifications
        #expect(notifications.map(\.body) == ["A", "B", "B"])
        #expect(notifications.map(\.subtitle) == ["A track", "", "B track"])
        #expect(await gate.authorizationRequests == 3)
    }

    @Test func backToBackStationAndTrackReserveOrderBeforeTasksBegin() async throws {
        let recorder = Recorder()
        let client = recorder.client
        let copy = client
        let coordinator = RadioNotificationCoordinator(client: copy)
        let station = try #require(coordinator.playbackStarted(
            identity: .init(id: UUID(), streamURL: "https://example.com/a"),
            title: "A", enabled: true
        ))
        let track = try #require(client.trackChanged(
            station: "A", previousTrack: "", track: "Track", isPlaying: true, enabled: true
        ))
        await station.value
        await track.value
        #expect(await recorder.notifications.map(\.subtitle) == ["", "Track"])
    }

    @Test func stationIdentityIncludesIDAndURLAndAllowsReturningToOriginal() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        let original = RadioPlayerItem(title: "Same name", streamUrl: "https://example.com/a", id: UUID())
        var other = original
        other.id = UUID()
        await start(original, using: coordinator)
        await start(other, using: coordinator)
        await start(original, using: coordinator)
        other = original
        other.streamUrl = "https://example.com/b"
        await start(other, using: coordinator)
        #expect(await recorder.notifications.count == 4)
    }

    @Test func disabledNotificationsStillFollowPlaybackWithoutRetroactiveResume() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        let item = RadioPlayerItem(title: "Station", streamUrl: "https://example.com/a", id: UUID())
        await start(item, using: coordinator, enabled: false)
        await start(item, using: coordinator, enabled: true)
        #expect(await recorder.notifications.isEmpty)
        #expect(await recorder.authorizationRequests == 0)
    }

    @Test func titleEditsAndPausedSelectionDoNotNotify() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        var item = RadioPlayerItem(title: "Station", streamUrl: "https://example.com/a", id: UUID())
        await start(item, using: coordinator)
        item.title = "Renamed"
        #expect(await recorder.notifications.count == 1)
        await start(item, using: coordinator)
        item.id = UUID()
        item.title = "Selected while paused"
        #expect(await recorder.notifications.count == 1)
    }

    @Test func previewAndPlayingRestorationEachNotifyOnce() async {
        let recorder = Recorder()
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        let original = RadioPlayerItem(title: "Original", streamUrl: "https://example.com/a", id: UUID())
        let preview = RadioPlayerItem(title: "Preview", streamUrl: "https://example.com/b", id: UUID())
        await start(original, using: coordinator)
        await start(preview, using: coordinator)
        await start(preview, using: coordinator)
        #expect(await recorder.notifications.map(\.body) == ["Original", "Preview"])
        await start(original, using: coordinator)
        #expect(await recorder.notifications.map(\.body) == ["Original", "Preview", "Original"])
    }

    @Test func payloadPreservesSpecialCharactersAndUsesUniqueIdentifiers() async {
        let recorder = Recorder()
        let station = "电台 \"quoted\" \\ path\n第二行 🎵"
        let track = "曲目 \"song\" \\ title\n新行 🎼"
        let client = recorder.client
        let stationNotification = RadioNotification.nowPlaying(station: station)
        let trackNotification = RadioNotification.nowPlaying(station: station, track: track)
        #expect(await client.send(stationNotification))
        #expect(await client.send(trackNotification))
        #expect(await recorder.notifications == [stationNotification, trackNotification])
        #expect(stationNotification.body == station)
        #expect(trackNotification.subtitle == track)
        #expect(trackNotification.title.isEmpty == false)
        #expect(stationNotification.identifier != trackNotification.identifier)
        #expect(await recorder.authorizationRequests == 2)
    }

    @Test(arguments: [false, true])
    func trackPreferencesAreIndependentOfStationNotifications(enabled: Bool) async {
        let recorder = Recorder()
        let task = recorder.client.trackChanged(station: "Station", previousTrack: "Old",
                                                track: "New", isPlaying: true, enabled: enabled)
        await task?.value
        #expect(await recorder.notifications.count == (enabled ? 1 : 0))
    }

    @Test func trackGuardsSuppressPausedEmptyAndDuplicateMetadata() async {
        let recorder = Recorder()
        let client = recorder.client
        let paused = client.trackChanged(station: "Station", previousTrack: "Old", track: "New",
                                         isPlaying: false, enabled: true)
        let emptyTrack = client.trackChanged(station: "Station", previousTrack: "Old", track: "",
                                             isPlaying: true, enabled: true)
        let emptyStation = client.trackChanged(station: "", previousTrack: "Old", track: "New",
                                               isPlaying: true, enabled: true)
        let duplicate = client.trackChanged(station: "Station", previousTrack: "Same", track: "Same",
                                            isPlaying: true, enabled: true)
        #expect(paused == nil)
        #expect(emptyTrack == nil)
        #expect(emptyStation == nil)
        #expect(duplicate == nil)
        #expect(await recorder.notifications.isEmpty)
    }

    @Test(arguments: [Outcome.denied, .authorizationFailure, .deliveryFailure])
    func failuresAreContainedAndFutureStationEventsContinue(_ outcome: Outcome) async {
        let recorder = Recorder(outcome: outcome)
        let coordinator = RadioNotificationCoordinator(client: recorder.client)
        let first = RadioPlayerItem(title: "First", streamUrl: "https://example.com/a", id: UUID())
        await start(first, using: coordinator)
        await recorder.setOutcome(.allowed)
        // A failed delivery never turns a same-station retry into another station change.
        await start(first, using: coordinator)
        var second = first
        second.id = UUID()
        second.title = "Second"
        await start(second, using: coordinator)
        #expect(await recorder.notifications.map(\.body) == ["Second"])
        #expect(await recorder.authorizationRequests == 2)
    }

    private func start(_ item: RadioPlayerItem, using coordinator: RadioNotificationCoordinator,
                       enabled: Bool = true) async {
        await coordinator.playbackStarted(identity: .init(id: item.id, streamURL: item.streamUrl),
                                           title: item.title, enabled: enabled)?.value
    }

    enum Outcome: Sendable {
        case allowed, denied, authorizationFailure, deliveryFailure
    }

    enum Failure: Error { case expected }

    actor AuthorizationGate {
        private(set) var authorizationRequests = 0
        private var requested = false
        private var released = false
        private var requestWaiter: CheckedContinuation<Void, Never>?
        private var authorizationWaiter: CheckedContinuation<Bool, Never>?

        func authorize() async -> Bool {
            authorizationRequests += 1
            if released { return true }
            requested = true
            requestWaiter?.resume()
            requestWaiter = nil
            return await withCheckedContinuation { authorizationWaiter = $0 }
        }

        func waitUntilRequested() async {
            if requested { return }
            await withCheckedContinuation { requestWaiter = $0 }
        }

        func release() {
            released = true
            authorizationWaiter?.resume(returning: true)
            authorizationWaiter = nil
        }
    }

    actor Recorder {
        var notifications: [RadioNotification] = []
        var authorizationRequests = 0
        var outcome: Outcome

        init(outcome: Outcome = .allowed) { self.outcome = outcome }

        nonisolated var client: RadioNotificationClient {
            RadioNotificationClient(
                requestAuthorization: { try await self.authorize() },
                deliver: { try await self.record($0) }
            )
        }

        func setOutcome(_ outcome: Outcome) { self.outcome = outcome }

        private func authorize() throws -> Bool {
            authorizationRequests += 1
            if outcome == .authorizationFailure { throw Failure.expected }
            return outcome != .denied
        }

        private func record(_ notification: RadioNotification) throws {
            if outcome == .deliveryFailure { throw Failure.expected }
            notifications.append(notification)
        }
    }
}

import Dependencies
import Extensions
import Foundation
import OSLog
import os
import UserNotifications

struct RadioNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let subtitle: String

    static func nowPlaying(station: String, track: String = "") -> Self {
        Self(identifier: UUID().uuidString, title: "Now Playing".localized(),
             body: station, subtitle: track)
    }
}

struct RadioNotificationClient: Sendable {
    var requestAuthorization: @Sendable () async throws -> Bool
    var deliver: @Sendable (RadioNotification) async throws -> Void
    private let deliveryQueue = RadioNotificationDeliveryQueue()

    init(requestAuthorization: @escaping @Sendable () async throws -> Bool,
         deliver: @escaping @Sendable (RadioNotification) async throws -> Void) {
        self.requestAuthorization = requestAuthorization
        self.deliver = deliver
    }

    @discardableResult
    func trackChanged(station: String, previousTrack: String, track: String,
                      isPlaying: Bool, enabled: Bool) -> Task<Bool, Never>? {
        guard enabled, isPlaying, !station.isEmpty, !track.isEmpty, track != previousTrack else {
            return nil
        }
        let notification = RadioNotification.nowPlaying(station: station, track: track)
        return enqueue(notification)
    }

    func authorize() async -> Bool {
        await Self.authorize(using: requestAuthorization)
    }

    private static func authorize(using request: @Sendable () async throws -> Bool) async -> Bool {
        do {
            let authorized = try await request()
            if !authorized { Logger.player.info("Radio notifications are not authorized") }
            return authorized
        } catch {
            Logger.player.error("Radio notification authorization failed: \(error)")
            return false
        }
    }

    @discardableResult
    func send(_ notification: RadioNotification) async -> Bool {
        await enqueue(notification).value
    }

    /// Reserve order synchronously so independent playback and metadata callers share one sequence.
    @discardableResult
    func enqueue(_ notification: RadioNotification) -> Task<Bool, Never> {
        let requestAuthorization = requestAuthorization
        let deliver = deliver
        return deliveryQueue.enqueue {
            guard await Self.authorize(using: requestAuthorization) else { return false }
            do {
                try await deliver(notification)
                return true
            } catch {
                Logger.player.error("Radio notification delivery failed: \(error)")
                return false
            }
        }
    }
}

/// Client copies share this lock-protected tail. Authorization and delivery run in queued tasks.
private final class RadioNotificationDeliveryQueue: Sendable {
    private let tail = OSAllocatedUnfairLock<Task<Bool, Never>?>(initialState: nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        tail.withLock { tail in
            let previous = tail
            let task = Task {
                _ = await previous?.value
                return await operation()
            }
            tail = task
            return task
        }
    }
}

extension RadioNotificationClient: DependencyKey {
    static let liveValue = Self(
        requestAuthorization: {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                return try await center.requestAuthorization(options: [.alert])
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                return false
            @unknown default:
                return false
            }
        },
        deliver: { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.subtitle = notification.subtitle
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
            )
        }
    )

    static let testValue = Self(requestAuthorization: { false }, deliver: { _ in })
}

extension DependencyValues {
    var radioNotification: RadioNotificationClient {
        get { self[RadioNotificationClient.self] }
        set { self[RadioNotificationClient.self] = newValue }
    }
}

//
//  RadioLibraryClient+App.swift
//  OnlySwitch
//

import AppKit
import Combine
import CoreData
import Extensions
import RadioBrowser
import Switches
import OnlySwitchPersistence

extension RadioLibraryClient {
    /// The live library: Core Data `RadioStations`, the shared radio player and the JSON import/export panels.
    static let app = Self(
        favorites: { try RadioLibraryAdapter.shared.favorites() },
        add: { try RadioLibraryAdapter.shared.add($0, favicon: $1, browserStationID: $2) },
        update: { try RadioLibraryAdapter.shared.update($0, with: $1) },
        delete: { try RadioLibraryAdapter.shared.delete($0) },
        play: { RadioLibraryAdapter.shared.play($0) },
        togglePlayback: { RadioLibraryAdapter.shared.togglePlayback() },
        preview: { RadioLibraryAdapter.shared.preview($0) },
        stopPreview: { RadioLibraryAdapter.shared.stopPreview() },
        retryPlayback: { RadioLibraryAdapter.shared.retryPlayback(sessionID: $0) },
        playbackStatus: { RadioLibraryAdapter.shared.playbackStatus() },
        playbackUpdates: {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task { @MainActor in
                    let player = RadioStationSwitch.shared.playerItem
                    let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let observation = player.$model.map { _ in () }
                        .merge(with: NotificationCenter.default.publisher(for: .ownPlaybackStateChanged).map { _ in () })
                        .sink { @Sendable _ in updates.continuation.yield(()) }
                    defer { observation.cancel() }
                    var lastStatus: RadioPlaybackStatus?
                    for await _ in updates.stream {
                        let status = RadioLibraryAdapter.shared.playbackStatus()
                        guard status != lastStatus else { continue }
                        lastStatus = status
                        continuation.yield(status)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        },
        importStations: { try await RadioLibraryAdapter.shared.importStations() },
        exportStations: { try await RadioLibraryAdapter.shared.exportStations() },
        copyToPasteboard: { string in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    )
}

@MainActor
final class RadioLibraryAdapter {
    static let shared = RadioLibraryAdapter()

    /// The browser station being auditioned, and what to restore when the audition ends.
    private var previewingStationID: String?
    private var restoreStationID: UUID?
    private var restoreWasPlaying = false

    private var context: NSManagedObjectContext { PersistenceController.shared.container.viewContext }
    private var player: RadioPlayerItemViewModel { RadioStationSwitch.shared.playerItem }

    func playbackStatus() -> RadioPlaybackStatus {
        guard let item = player.model else { return RadioPlaybackStatus() }
        let hosted = PlayerManager.shared.player as? HostedAudioPlayer
        let session = hosted?.radioSession.flatMap { $0.matches(item) ? $0 : nil }
        return RadioPlaybackStatus(
            currentID: item.id,
            isPlaying: item.isPlaying,
            previewingStationID: previewingStationID,
            title: item.title,
            streamInfo: item.isPlaying ? item.streamInfo : "",
            phase: session?.phase ?? .idle,
            sessionID: session?.id
        )
    }

    // MARK: Favorites

    func favorites() throws -> [RadioFavorite] {
        try PersistenceController.shared.requireStore()
        var seen = Set<UUID>()
        return try context.fetch(RadioStations.defaultFetchRequest).compactMap { station in
            guard let id = station.id, let title = station.title, let url = station.url, seen.insert(id).inserted else { return nil }
            return RadioFavorite(
                id: id,
                name: title,
                streamURL: url,
                favicon: station.favicon.flatMap(URL.init(string:)),
                browserStationID: station.browserStationID
            )
        }
    }

    func add(_ station: RadioFavoriteDraft.Valid, favicon: URL?, browserStationID: String?) throws -> RadioFavorite {
        try PersistenceController.shared.requireStore()
        let radio = RadioStations(context: context)
        radio.id = UUID()
        radio.title = station.name
        radio.url = station.streamURL
        radio.favicon = favicon?.absoluteString
        radio.browserStationID = browserStationID
        radio.timestamp = Date()
        try save()
        return RadioFavorite(id: radio.id!, name: station.name, streamURL: station.streamURL, favicon: favicon, browserStationID: browserStationID)
    }

    func update(_ id: UUID, with station: RadioFavoriteDraft.Valid) throws {
        try PersistenceController.shared.requireStore()
        guard let radio = RadioStations.fetchRequest(by: id).first else { return }
        let urlChanged = radio.url != station.streamURL
        radio.title = station.name
        radio.url = station.streamURL
        if urlChanged {
            // A different stream invalidates the logo and browser identity it came with.
            radio.favicon = nil
            radio.browserStationID = nil
        }
        try save()
        guard previewingStationID == nil, player.id == id else { return }
        let wasPlaying = player.isPlaying
        if urlChanged, wasPlaying { player.isPlaying = false }
        player.model.artworkURL = radio.favicon.flatMap(URL.init(string:))
        player.title = station.name
        player.streamUrl = station.streamURL
        if urlChanged, wasPlaying { player.isPlaying = true }
        refreshSwitch()
    }

    func delete(_ id: UUID) throws {
        try PersistenceController.shared.requireStore()
        guard RadioStations.fetchResult.count > 1 else { throw RadioLibraryError.atLeastOneStation }
        guard let radio = RadioStations.fetchRequest(by: id).first else { return }
        if previewingStationID == nil, player.id == id {
            player.nextStation()
        }
        if restoreStationID == id {
            restoreStationID = nil
        }
        context.delete(radio)
        try save()
    }

    // MARK: Playback

    func play(_ id: UUID) {
        guard Preferences.shared.radioEnable,
              let station = RadioStations.fetchRequest(by: id).first(where: { $0.title != nil && $0.url != nil })
        else { return }
        previewingStationID = nil
        restoreStationID = nil
        RadioStationSwitch.shared.setPlayerItem(station: station)
        Preferences.shared.radioStationID = id.uuidString
        player.isPlaying = true
        refreshSwitch()
    }

    func togglePlayback() {
        guard Preferences.shared.radioEnable else { return }
        player.isPlaying.toggle()
        refreshSwitch()
    }

    func retryPlayback(sessionID: UUID) {
        guard Preferences.shared.radioEnable else { return }
        let status = playbackStatus()
        guard status.sessionID == sessionID, status.phase.canRetry else { return }
        // Restart the selected favorite or audition in place, keeping the audition's restore target.
        player.isPlaying = true
        refreshSwitch()
    }

    func preview(_ station: RadioBrowserStation) {
        guard Preferences.shared.radioEnable else { return }
        if previewingStationID == nil {
            restoreStationID = player.id
            restoreWasPlaying = player.isPlaying
        }
        previewingStationID = station.id
        if player.isPlaying { player.isPlaying = false }
        player.model.artworkURL = station.favicon
        player.title = station.name
        player.streamUrl = station.streamURL.absoluteString
        player.streamInfo = ""
        // A transient identity: next/previous and edits never match it to a saved station.
        player.id = UUID()
        player.isPlaying = true
        refreshSwitch()
    }

    func stopPreview() {
        guard previewingStationID != nil else { return }
        previewingStationID = nil
        player.isPlaying = false
        let restored = restoreStationID.flatMap { RadioStations.fetchRequest(by: $0).first } ?? RadioStations.fetchResult.first
        if let restored {
            RadioStationSwitch.shared.setPlayerItem(station: restored)
            if restoreWasPlaying && Preferences.shared.radioEnable { player.isPlaying = true }
        }
        restoreStationID = nil
        refreshSwitch()
    }

    // MARK: Import / Export

    func importStations() async throws -> Int? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard await panel.response() == .OK, let url = panel.url else { return nil }
        let items = try JSONDecoder().decode([RadioItem].self, from: Data(contentsOf: url))
        let before = RadioStations.fetchResult.count
        try RadioStations.restore(items.map { RadioStationBackup(title: $0.name, url: $0.url) })
        NotificationCenter.default.post(name: .changeSettings, object: nil)
        return RadioStations.fetchResult.count - before
    }

    func exportStations() async throws -> Bool {
        let list = try favorites().map { RadioItem(name: $0.name, url: $0.streamURL) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(list)
        let panel = NSSavePanel()
        panel.title = "Save Radio List"
        panel.nameFieldStringValue = "radio_list"
        panel.allowedContentTypes = [.json]
        guard await panel.response() == .OK, let url = panel.url else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    // MARK: Helpers

    private func save() throws {
        if context.hasChanges {
            try context.save()
        }
        NotificationCenter.default.post(name: .changeSettings, object: nil)
    }

    private func refreshSwitch() {
        NotificationCenter.default.post(name: .refreshSingleSwitchStatus, object: SwitchType.radioStation)
    }
}

private extension NSSavePanel {
    func response() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}

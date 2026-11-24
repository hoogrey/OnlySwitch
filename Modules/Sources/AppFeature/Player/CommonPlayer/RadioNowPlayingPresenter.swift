import AppKit
import MediaPlayer

/// The host owns Control Center state. The helper owns the player clock and stream metadata.
@MainActor
final class RadioNowPlayingPresenter {
    private var state: NowPlayingMetadataState?
    private var stationIconTask: Task<Void, Never>?
    private var imageData: Data?
    private var artwork: MPMediaItemArtwork?

    func start(id: UUID, station: String, icon: URL?) {
        invalidate()
        state = NowPlayingMetadataState(playbackID: id, station: station)
        publish()
        guard let icon else { return }
        stationIconTask = Task { [weak self] in
            guard let data = await RadioArtwork.stationIcon(from: icon),
                  !Task.isCancelled, let self, self.state?.playbackID == id else { return }
            self.state?.setStationArtwork(data, playbackID: id)
            self.publish()
        }
    }

    func receive(_ event: PlaybackHelperEvent) {
        guard let id = event.playbackID, id == state?.playbackID else { return }
        if let title = event.trackInfo { state?.setProgram(title) }
        if let data = event.programArtwork, data.count <= RadioArtwork.maximumThumbnailBytes {
            state?.setProgramArtwork(data, playbackID: id, program: event.artworkProgram)
        }
        if let timing = event.timing {
            state?.updateTiming(elapsed: timing.elapsed, duration: timing.duration, isPlaying: timing.isPlaying)
        } else if event.isReady == true {
            state?.updateTiming(elapsed: nil, duration: nil, isPlaying: true)
        }
        if event.trackInfo != nil || event.programArtwork != nil || event.timing != nil || event.isReady == true { publish() }
    }

    func stop() {
        guard state != nil else { return }
        state?.setProgram(nil)
        state?.updateTiming(elapsed: nil, duration: nil, isPlaying: false)
        publish()
        invalidate()
    }

    func invalidate() {
        stationIconTask?.cancel()
        stationIconTask = nil
        state = nil
        imageData = nil
        artwork = nil
    }

    private func publish() {
        guard let state else { return }
        let data = state.artworkData
        if artwork == nil || imageData != data {
            imageData = data
            artwork = nil
            if let image = data.flatMap(NSImage.init(data:)) ?? NSImage(named: "AppIcon") {
                if let imageData = image.tiffRepresentation {
                    artwork = Self.makeArtwork(data: imageData, size: image.size)
                }
            }
        }
        var info = state.mediaInfo
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated static func makeArtwork(data: Data, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            NSImage(data: data) ?? NSImage(size: size)
        }
    }

    deinit { stationIconTask?.cancel() }
}

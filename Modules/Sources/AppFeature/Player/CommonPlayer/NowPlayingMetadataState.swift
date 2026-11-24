import Foundation
import MediaPlayer

struct NowPlayingMetadataState {
    let playbackID: UUID
    let station: String
    private(set) var program: String?
    private var stationArtwork: Data?
    private var programArtwork: Data?
    private var elapsed: Double?
    private var duration: Double?
    private var isPlaying: Bool?

    init(playbackID: UUID, station: String) {
        self.playbackID = playbackID
        self.station = station
    }

    var artworkData: Data? { programArtwork ?? stationArtwork }

    mutating func setProgram(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed == "" ? nil : trimmed
        guard program != next else { return }
        program = next
        programArtwork = nil
    }

    mutating func setStationArtwork(_ data: Data, playbackID: UUID) {
        guard self.playbackID == playbackID else { return }
        stationArtwork = data
    }

    mutating func setProgramArtwork(_ data: Data, playbackID: UUID, program: String?) {
        guard self.playbackID == playbackID, self.program == program else { return }
        programArtwork = data
    }

    mutating func updateTiming(elapsed: Double?, duration: Double?, isPlaying: Bool) {
        self.isPlaying = isPlaying
        guard let duration, duration.isFinite, duration > 0,
              let elapsed, elapsed.isFinite, (0...duration).contains(elapsed) else {
            self.duration = nil
            self.elapsed = nil
            return
        }
        self.elapsed = elapsed
        self.duration = duration
    }

    var mediaInfo: [String: Any] {
        var fields: [String: Any] = [
            MPMediaItemPropertyTitle: program ?? station,
            MPNowPlayingInfoPropertyIsLiveStream: duration == nil,
        ]
        if let isPlaying { fields[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0 }
        if program != nil { fields[MPMediaItemPropertyArtist] = station }
        fields[MPMediaItemPropertyPlaybackDuration] = duration
        fields[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        return fields
    }
}

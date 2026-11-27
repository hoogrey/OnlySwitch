import Foundation
import RadioBrowser

/// Identifies both the play request and the station it belongs to. The Radio view model
/// is reused for different favorites and previews.
struct RadioPlaybackSession: Equatable {
    let id: UUID
    let stationID: UUID
    let streamURL: String
    var phase: RadioPlaybackPhase

    func matches(_ item: RadioPlayerItem) -> Bool {
        stationID == item.id && streamURL == item.streamUrl
    }

    mutating func receive(_ event: PlaybackHelperEvent) -> Bool {
        guard id == event.playbackID, let phase = event.radioPhase, self.phase != phase else { return false }
        self.phase = phase
        return true
    }
}

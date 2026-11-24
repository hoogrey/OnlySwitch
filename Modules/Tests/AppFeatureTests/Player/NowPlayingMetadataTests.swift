import AppKit
import Foundation
import MediaPlayer
import Testing
@testable import AppFeature

struct NowPlayingMetadataTests {
    @Test @MainActor func artworkCanBeRequestedOnABackgroundQueue() async throws {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        image.addRepresentation(bitmap)
        let data = try #require(image.tiffRepresentation)
        let artwork = RadioNowPlayingPresenter.makeArtwork(data: data, size: image.size)
        let result = await Task.detached {
            artwork.image(at: NSSize(width: 12, height: 12)) != nil
        }.value
        #expect(result)
    }

    @Test func currentProgramArtworkWinsAndChangingProgramsRestoresTheStationIcon() {
        let playbackID = UUID()
        var state = NowPlayingMetadataState(playbackID: playbackID, station: "City Radio")
        let stationIcon = Data([1])
        let firstCover = Data([2])
        #expect(state.artworkData == nil)
        state.setProgram("Morning Jazz")
        state.setProgramArtwork(firstCover, playbackID: playbackID, program: "Morning Jazz")
        state.setStationArtwork(stationIcon, playbackID: playbackID)
        #expect(state.artworkData == firstCover)
        #expect(state.mediaInfo[MPMediaItemPropertyTitle] as? String == "Morning Jazz")

        state.setProgram("The News")
        state.setProgramArtwork(firstCover, playbackID: playbackID, program: "Morning Jazz")
        #expect(state.artworkData == stationIcon)
        state.setProgram(nil)
        #expect(state.mediaInfo[MPMediaItemPropertyTitle] as? String == "City Radio")
    }

    @Test func returningToTheSameStationRejectsArtworkFromThePreviousSession() {
        let formerPlaybackID = UUID()
        let playbackID = UUID()
        var state = NowPlayingMetadataState(playbackID: playbackID, station: "City Radio")
        state.setProgram("Evening")
        state.setStationArtwork(Data([1]), playbackID: formerPlaybackID)
        state.setProgramArtwork(Data([2]), playbackID: formerPlaybackID, program: "Evening")
        #expect(state.artworkData == nil)
        state.setStationArtwork(Data([3]), playbackID: playbackID)
        #expect(state.artworkData == Data([3]))
    }

    @Test func unknownLiveDurationOmitsTimelineAndReflectsPlaybackRate() {
        var state = NowPlayingMetadataState(playbackID: UUID(), station: "Live")
        state.updateTiming(elapsed: 20, duration: nil, isPlaying: true)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(state.mediaInfo[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        state.updateTiming(elapsed: 20, duration: nil, isPlaying: false)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test func boundedProgramPublishesOnlyAValidMediaTimeline() {
        var state = NowPlayingMetadataState(playbackID: UUID(), station: "Concert")
        state.updateTiming(elapsed: 15, duration: 90, isPlaying: false)
        #expect(state.mediaInfo[MPMediaItemPropertyPlaybackDuration] as? Double == 90)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 15)
        #expect(state.mediaInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        for (elapsed, duration) in [(Double.nan, 90.0), (0, Double.infinity), (91, 90), (0, 0)] {
            state.updateTiming(elapsed: elapsed, duration: duration, isPlaying: true)
            #expect(state.mediaInfo[MPMediaItemPropertyPlaybackDuration] == nil)
            #expect(state.mediaInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
        }
    }
}

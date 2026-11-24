import AVFoundation
import Extensions
import Foundation
import os

/// Only the helper constructs audible AVFoundation players. The host retains UI, Now Playing,
/// track navigation and user preferences, while metadata and waveform samples return over stdout.
@MainActor
final class PlaybackHelperEngine: NSObject, @preconcurrency AVPlayerItemMetadataOutputPushDelegate, StreamingDelegate {
    private var player: AVPlayer?
    private var noise: AVAudioPlayer?
    private var streamer: Streamer?
    private var playbackObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var metadataReader: RadioStreamMetadataReader?
    private var assetMetadataTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var lastTiming: RadioPlaybackTiming?
    private var reconnectURL: URL?
    private var reconnect = RadioReconnect()
    private var reconnectTask: Task<Void, Never>?
    private var radioHasPlayed = false
    private var receivedStreamAudio = false
    private var desiredPlaybackActive = false
    private var playbackID: UUID?
    private let output: FileHandle
    private var volume: Float = 1
    nonisolated private let visible = OSAllocatedUnfairLock(initialState: false)
    private let analyzer = RealtimeAnalyzer(fftSize: bufferSize)

    init(output: FileHandle) { self.output = output; super.init() }

    func announceReady() { emit(.init(isReady: true)) }

    func perform(_ command: PlaybackHelperCommand) {
        switch command.action {
        case .play:
            guard let raw = command.url, raw.utf8.count <= 8_192,
                  let url = URL(string: raw), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
            stop()
            playbackID = command.playbackID
            desiredPlaybackActive = true
            setVolume(command.volume ?? volume)
            if command.isNoise == true {
                guard let sound = try? AVAudioPlayer(contentsOf: url) else {
                    emit(.init(isBuffering: false, hasFailed: true)); return
                }
                noise = sound
                sound.numberOfLoops = -1
                sound.volume = volume
                emit(.init(isBuffering: false, hasFailed: !sound.play()))
            } else {
                reconnectURL = RadioReconnect.supports(url) ? url : nil
                let path = raw.lowercased()
                let useStreamer = command.usesWaveform == true && reconnectURL == nil && !path.hasSuffix(".m3u")
                    && !path.hasSuffix(".m3u8") && !path.hasSuffix(".aac")
                startRadio(url: url, muted: useStreamer)
                if useStreamer {
                    let stream = Streamer()
                    stream.delegate = self
                    stream.volume = volume
                    streamer = stream
                    stream.url = url
                    // Preserve incremental live-radio startup before the download ever completes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak stream] in
                        guard let self, let stream, self.streamer === stream, self.desiredPlaybackActive else { return }
                        stream.play()
                    }
                }
            }
        case .pause:
            desiredPlaybackActive = false
            cancelReconnect()
            player?.pause(); noise?.pause(); streamer?.pause()
            emit(.init(isBuffering: false))
        case .stop:
            stop()
        case .volume:
            setVolume(command.volume ?? volume)
        case .visible:
            visible.withLock { $0 = command.isVisible == true }
        case .shutdown:
            shutdown()
        }
    }

    private func startRadio(url: URL, muted: Bool) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        let metadata = AVPlayerItemMetadataOutput(identifiers: nil)
        metadata.setDelegate(self, queue: .main)
        item.add(metadata)
        let av = AVPlayer(playerItem: item)
        player = av
        lastTiming = nil
        let reader = RadioStreamMetadataReader { [weak self, weak av] event in
            guard let self, let av, self.player === av, self.desiredPlaybackActive else { return }
            self.emit(event)
        }
        metadataReader = reader
        assetMetadataTask = Task { [weak reader] in
            guard let common = try? await item.asset.load(.commonMetadata), !Task.isCancelled else { return }
            reader?.read(common, timed: false)
        }
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                                                   queue: .main) { [weak self, weak av] _ in
            MainActor.assumeIsolated {
                guard let self, let av, self.player === av, self.desiredPlaybackActive else { return }
                self.updateTiming(av)
            }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.desiredPlaybackActive,
                      let av = self.player, av.currentItem === item else { return }
                if self.reconnectURL != nil {
                    self.updateRadioStatus(av)
                } else {
                    self.emit(.init(isBuffering: false, hasFailed: true))
                }
            }
        }
        playbackObservation = av.observe(\.timeControlStatus, options: [.new]) { [weak self] av, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player === av, self.desiredPlaybackActive else { return }
                self.updateRadioStatus(av)
            }
        }
        av.volume = volume
        av.isMuted = muted
        emit(.init(isBuffering: true))
        av.play()
        if reconnectURL != nil { updateRadioStatus(av) }
    }

    private func updateRadioStatus(_ av: AVPlayer) {
        updateTiming(av)
        let failed = av.currentItem?.status == .failed
        let isBuffering = failed || av.timeControlStatus != .playing
        guard let url = reconnectURL else {
            emit(.init(isBuffering: isBuffering))
            return
        }

        if !isBuffering {
            radioHasPlayed = true
            cancelReconnect()
            reconnect.reset()
        } else if failed, !radioHasPlayed || reconnect.delay == nil {
            cancelReconnect()
            desiredPlaybackActive = false
            emit(.init(isBuffering: false, hasFailed: true))
            return
        } else if !needsReconnect(av) {
            cancelReconnect()
        } else if radioHasPlayed, reconnectTask == nil, let delay = reconnect.delay {
            scheduleReconnect(for: av, url: url, after: delay)
        }
        emit(.init(isBuffering: isBuffering))
    }

    private func updateTiming(_ av: AVPlayer) {
        // With waveform playback the AVPlayer is a muted metadata reader with a separate clock.
        guard !av.isMuted, let item = av.currentItem else { return }
        let playing = av.timeControlStatus == .playing
        var timing = RadioPlaybackTiming(isPlaying: playing)
        // A live HLS DVR window measures the playlist, not the current program.
        let playbackType = item.accessLog()?.events.last?.playbackType?.uppercased()
        let isFiniteMedia = playbackType == "VOD" || playbackType == "FILE"
        let ext = (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() ?? ""
        let directAudio = ["mp3", "aac", "m4a", "wav", "aif", "aiff", "flac"].contains(ext)
            && playbackType != "LIVE" && item.currentDate() == nil
        let duration = item.duration.seconds
        let elapsed = item.currentTime().seconds
        if (isFiniteMedia || directAudio), duration.isFinite, duration > 0,
           elapsed.isFinite, (0...duration).contains(elapsed) {
            timing.duration = duration
            timing.elapsed = elapsed
        }
        guard timing != lastTiming else { return }
        lastTiming = timing
        emit(.init(timing: timing))
    }

    private func needsReconnect(_ av: AVPlayer) -> Bool {
        av.timeControlStatus == .waitingToPlayAtSpecifiedRate || av.currentItem?.status == .failed
    }

    private func scheduleReconnect(for av: AVPlayer, url: URL, after delay: Duration) {
        reconnectTask = Task { [weak self, weak av] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let av, self.player === av,
                  self.desiredPlaybackActive else { return }
            self.reconnectTask = nil
            guard self.needsReconnect(av) else {
                self.updateRadioStatus(av)
                return
            }
            self.reconnect.recordAttempt()
            Logger.player.info("Restarting stalled HLS radio playback (attempt \(self.reconnect.attempts))")
            self.retireRadioPlayer()
            self.startRadio(url: url, muted: false)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func retireRadioPlayer() {
        metadataReader?.invalidate()
        metadataReader = nil
        assetMetadataTask?.cancel()
        assetMetadataTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playbackObservation = nil
        itemObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func setVolume(_ value: Float) {
        volume = value.isFinite ? min(1, max(0, value)) : 0
        player?.volume = volume
        noise?.volume = volume
        streamer?.setUserVolume(volume)
    }

    private func stop(emitStatus: Bool = true) {
        desiredPlaybackActive = false
        cancelReconnect()
        reconnect.reset()
        reconnectURL = nil
        radioHasPlayed = false
        retireRadioPlayer()
        noise?.stop()
        streamer?.dispose()
        receivedStreamAudio = false
        noise = nil; streamer = nil
        if emitStatus { emit(.init(isBuffering: false)) }
    }

    func shutdown() -> Never { stop(emitStatus: false); exit(EXIT_SUCCESS) }

    private func emit(_ event: PlaybackHelperEvent) {
        var event = event
        event.playbackID = playbackID
        guard var data = try? JSONEncoder().encode(event), data.count <= PlaybackHelperLineFramer.maximumFrameSize else { return }
        data.append(10)
        do { try output.write(contentsOf: data) } catch { shutdown() }
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        guard desiredPlaybackActive, player?.currentItem?.outputs.contains(where: { $0 === output }) == true else { return }
        for group in groups { metadataReader?.read(group.items, timed: true) }
    }

    nonisolated func streamer(_ streamer: Streaming, downloadComplete url: URL) {
        guard let stream = streamer as? Streamer else { return }
        Task { @MainActor [weak self] in
            guard let self, self.streamer === stream, self.desiredPlaybackActive else { return }
            stream.play()
        }
    }

    nonisolated func streamer(_ streamer: Streaming, failedDownloadWithError error: Error, forURL url: URL) {
        guard let stream = streamer as? Streamer else { return }
        Task { @MainActor [weak self] in
            guard let self, self.streamer === stream else { return }
            stream.dispose()
            self.streamer = nil
            self.player?.isMuted = false
            if self.desiredPlaybackActive { self.emit(.init(isBuffering: false, isReady: true)) }
        }
    }

    nonisolated func streamer(_ streamer: Streaming, updateBuffer buffer: AVAudioPCMBuffer) {
        guard let stream = streamer as? Streamer else { return }
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        let interleaved = buffer.format.isInterleaved
        let samples: [[Float]]?
        if visible.withLock({ $0 }), buffer.frameLength >= AVAudioFrameCount(bufferSize),
           channelCount > 0, channelCount <= 8, let channels = buffer.floatChannelData {
            // Copy only samples across the actor boundary; the engine owns and reuses its buffer.
            samples = (0..<channelCount).map { channel in
                (0..<bufferSize).map { frame in
                    interleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                }
            }
        } else { samples = nil }
        Task { @MainActor [weak self] in
            guard let self, self.streamer === stream else { return }
            var spectra: [[Float]]?
            if let samples,
               let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)),
               let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferSize)),
               let channels = copy.floatChannelData {
                copy.frameLength = AVAudioFrameCount(bufferSize)
                for channel in 0..<channelCount {
                    samples[channel].withUnsafeBufferPointer { source in
                        channels[channel].update(from: source.baseAddress!, count: bufferSize)
                    }
                }
                spectra = self.analyzer.analyse(with: copy)
            }
            let firstAudio = !self.receivedStreamAudio
            self.receivedStreamAudio = true
            if firstAudio || spectra != nil {
                self.emit(.init(spectra: spectra, isBuffering: false, isReady: firstAudio))
            }
        }
    }
    nonisolated func streamer(_ streamer: Streaming, updatedDownloadProgress progress: Float, forURL url: URL) {}
    nonisolated func streamer(_ streamer: Streaming, changedState state: StreamingState) {}
    nonisolated func streamer(_ streamer: Streaming, updatedCurrentTime currentTime: TimeInterval) {}
    nonisolated func streamer(_ streamer: Streaming, updatedDuration duration: TimeInterval) {}
}

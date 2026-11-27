import AVFoundation
import Extensions
import Foundation
import os
import RadioBrowser

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
    private var recovery = RadioPlaybackRecovery()
    private var reconnectTask: Task<Void, Never>?
    private var itemEndObservation: (any NSObjectProtocol)?
    private var itemFailedEndObservation: (any NSObjectProtocol)?
    private var lastRadioPhase: RadioPlaybackPhase?
    private var currentItemFailed = false
    private var currentItemEnded = false
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
                publishRadioPhase(.connecting)
                startRadio(url: url, muted: useStreamer)
                if useStreamer {
                    let stream = Streamer()
                    stream.delegate = self
                    stream.audibleObservation = StreamerAudibleObservation { [weak self, weak stream] state in
                        guard let self, let stream, self.streamer === stream, self.desiredPlaybackActive else { return }
                        switch state {
                        case .buffering: self.observeRadio(.buffering)
                        case .playing: self.observeRadio(.playing)
                        case .ended: self.finishRadio()
                        case .unavailable: self.fallbackToAVPlayer(from: stream)
                        }
                    }
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
            if player != nil { publishRadioPhase(.paused) } else { emit(.init(isBuffering: false)) }
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
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let av = self.player, av.currentItem === item else { return }
                self.updateRadioStatus(av)
            }
        }
        playbackObservation = av.observe(\.timeControlStatus, options: [.new]) { [weak self] av, _ in
            DispatchQueue.main.async { [weak self] in self?.updateRadioStatus(av) }
        }
        itemEndObservation = observeItem(.AVPlayerItemDidPlayToEndTime, player: av, item: item) { engine, av in
            engine.currentItemEnded = true
            if !av.isMuted { engine.finishRadio() }
        }
        itemFailedEndObservation = observeItem(.AVPlayerItemFailedToPlayToEndTime, player: av, item: item) { engine, av in
            engine.currentItemFailed = true
            engine.updateRadioStatus(av)
        }
        av.volume = volume
        av.isMuted = muted
        av.play()
        updateRadioStatus(av)
    }

    private func observeItem(
        _ name: Notification.Name,
        player av: AVPlayer,
        item: AVPlayerItem,
        perform: @escaping @MainActor @Sendable (PlaybackHelperEngine, AVPlayer) -> Void
    ) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self, weak av] _ in
            MainActor.assumeIsolated {
                guard let self, let av, self.player === av, av.currentItem === item,
                      self.desiredPlaybackActive else { return }
                perform(self, av)
            }
        }
    }

    private func updateRadioStatus(_ av: AVPlayer) {
        guard player === av, desiredPlaybackActive, !av.isMuted else { return }
        updateTiming(av)
        let observation: RadioPlaybackRecovery.Observation
        if currentItemFailed || av.currentItem?.status == .failed {
            observation = .failed
        } else {
            switch av.timeControlStatus {
            case .playing: observation = .playing
            case .waitingToPlayAtSpecifiedRate:
                observation = av.currentItem?.status == .readyToPlay ? .buffering : .connecting
            default:
                observation = recovery.hasPlayed ? .interrupted : .connecting
            }
        }
        observeRadio(observation, player: av)
    }

    private func observeRadio(_ observation: RadioPlaybackRecovery.Observation, player av: AVPlayer? = nil) {
        recovery.observe(observation, allowsRetry: reconnectURL != nil)
        if recovery.hasFailed {
            desiredPlaybackActive = false
            cancelReconnect()
            publishRadioPhase(recovery.phase, failed: true)
            return
        }

        let phase = recovery.phase
        publishRadioPhase(phase)
        guard let av, let url = reconnectURL else { return }
        if observation != .playing, recovery.awaitsFinalResult {
            if reconnectTask == nil { scheduleFinalResult(for: av) }
        } else if observation == .playing || !needsReconnect(av) {
            cancelReconnect()
        } else if recovery.hasPlayed, reconnectTask == nil, let delay = recovery.retry.delay {
            scheduleReconnect(for: av, url: url, after: delay)
        }
    }

    private func publishRadioPhase(_ phase: RadioPlaybackPhase, failed: Bool = false, ended: Bool = false) {
        guard lastRadioPhase != phase || failed || ended else { return }
        lastRadioPhase = phase
        let buffering: Bool
        switch phase {
        case .connecting, .buffering, .waitingToRetry, .reconnecting: buffering = true
        default: buffering = false
        }
        let timing = streamer.map { _ in RadioPlaybackTiming(isPlaying: phase == .playing || phase == .recovered) }
        emit(.init(timing: timing, isBuffering: buffering, hasFailed: failed ? true : nil,
                   radioPhase: phase, radioEnded: ended ? true : nil))
    }

    private func finishRadio() {
        desiredPlaybackActive = false
        cancelReconnect()
        publishRadioPhase(.idle, ended: true)
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
        currentItemFailed || av.currentItem?.status == .failed || av.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func scheduleReconnect(for av: AVPlayer, url: URL, after delay: Duration) {
        reconnectTask = Task { [weak self, weak av] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, let av, self.player === av,
                  self.desiredPlaybackActive else { return }
            self.reconnectTask = nil
            guard self.needsReconnect(av) else {
                self.updateRadioStatus(av)
                return
            }
            self.recovery.beginAttempt()
            self.publishRadioPhase(self.recovery.phase)
            Logger.player.info("Restarting stalled HLS radio playback (attempt \(self.recovery.retry.attempts))")
            self.retireRadioPlayer()
            self.startRadio(url: url, muted: false)
        }
    }

    private func scheduleFinalResult(for av: AVPlayer) {
        reconnectTask = Task { [weak self, weak av] in
            do { try await Task.sleep(for: RadioReconnect.finalResultDelay) } catch { return }
            guard !Task.isCancelled, let self, let av, self.player === av, self.desiredPlaybackActive else { return }
            self.reconnectTask = nil
            if av.timeControlStatus == .playing {
                self.updateRadioStatus(av)
                return
            }
            self.recovery.finishWaitingForFinalResult()
            self.publishRadioPhase(self.recovery.phase)
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
        if let itemEndObservation { NotificationCenter.default.removeObserver(itemEndObservation) }
        if let itemFailedEndObservation { NotificationCenter.default.removeObserver(itemFailedEndObservation) }
        itemEndObservation = nil
        itemFailedEndObservation = nil
        currentItemFailed = false
        currentItemEnded = false
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
        recovery = RadioPlaybackRecovery()
        reconnectURL = nil
        lastRadioPhase = nil
        retireRadioPlayer()
        noise?.stop()
        streamer?.dispose()
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
            self?.fallbackToAVPlayer(from: stream)
        }
    }

    private func fallbackToAVPlayer(from stream: Streamer) {
        guard streamer === stream, desiredPlaybackActive else { return }
        streamer = nil
        stream.dispose()
        if let player {
            if currentItemEnded, let url = (player.currentItem?.asset as? AVURLAsset)?.url {
                // Short media may have already ended on the silent metadata clock.
                retireRadioPlayer()
                startRadio(url: url, muted: false)
            } else {
                player.isMuted = false
                updateRadioStatus(player)
            }
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
        guard let samples else { return }
        Task { @MainActor [weak self] in
            guard let self, self.streamer === stream, self.desiredPlaybackActive else { return }
            if let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)),
               let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferSize)),
               let channels = copy.floatChannelData {
                copy.frameLength = AVAudioFrameCount(bufferSize)
                for channel in 0..<channelCount {
                    samples[channel].withUnsafeBufferPointer { source in
                        channels[channel].update(from: source.baseAddress!, count: bufferSize)
                    }
                }
                self.emit(.init(spectra: self.analyzer.analyse(with: copy)))
            }
        }
    }
    nonisolated func streamer(_ streamer: Streaming, updatedDownloadProgress progress: Float, forURL url: URL) {}
    nonisolated func streamer(_ streamer: Streaming, changedState state: StreamingState) {}
    nonisolated func streamer(_ streamer: Streaming, updatedCurrentTime currentTime: TimeInterval) {}
    nonisolated func streamer(_ streamer: Streaming, updatedDuration duration: TimeInterval) {}
}

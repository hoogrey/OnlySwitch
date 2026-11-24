import AVFoundation

/// One reader per AVPlayerItem. Retiring the item also retires its pending artwork.
@MainActor
final class RadioStreamMetadataReader {
    private let emit: (PlaybackHelperEvent) -> Void
    private var program: String?
    private var artworkVersion = UUID()
    private var didReceiveTimedMetadata = false

    init(emit: @escaping (PlaybackHelperEvent) -> Void) {
        self.emit = emit
    }

    func read(_ items: [AVMetadataItem], timed: Bool) {
        guard timed || !didReceiveTimedMetadata else { return }
        var newTitle: String?
        var rawArtwork: Data?
        for item in items {
            if item.commonKey == .commonKeyTitle || item.identifier == .icyMetadataStreamTitle ||
                item.identifier == .id3MetadataTitleDescription {
                // Values delivered in a timed group are already available on the delegate queue.
                newTitle = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if item.commonKey == .commonKeyArtwork || item.identifier == .id3MetadataAttachedPicture {
                rawArtwork = item.dataValue ?? (item.value as? NSDictionary)?["data"] as? Data
            }
        }
        guard newTitle != nil || rawArtwork != nil else { return }
        if timed { didReceiveTimedMetadata = true }
        if let newTitle {
            let bounded = String(newTitle.prefix(1_024))
            if bounded != program {
                invalidate()
                program = bounded.isEmpty ? nil : bounded
                emit(.init(trackInfo: bounded))
            }
        }
        guard let rawArtwork, rawArtwork.count <= RadioArtwork.maximumInputBytes else { return }
        let version = UUID()
        artworkVersion = version
        let owner = program
        StreamArtworkWorker.shared.submit(rawArtwork, id: version) { [weak self] thumbnail in
            guard let self, self.artworkVersion == version, self.program == owner else { return }
            self.emit(.init(programArtwork: thumbnail, artworkProgram: owner))
        }
    }

    func invalidate() {
        StreamArtworkWorker.shared.discard(id: artworkVersion)
        artworkVersion = UUID()
    }
}

/// The helper has one playback engine. At most one picture decodes while the newest pending picture waits.
@MainActor
private final class StreamArtworkWorker {
    static let shared = StreamArtworkWorker()

    private struct Request {
        let data: Data
        let id: UUID
        let deliver: (Data) -> Void
    }

    private var pending: Request?
    private var running = false

    func submit(_ data: Data, id: UUID, deliver: @escaping (Data) -> Void) {
        pending = Request(data: data, id: id, deliver: deliver)
        guard !running else { return }
        running = true
        Task {
            while let request = pending {
                pending = nil
                let bytes = request.data
                let result = await Task.detached(priority: .utility) { RadioArtwork.thumbnail(bytes) }.value
                if let result { request.deliver(result) }
            }
            running = false
        }
    }

    func discard(id: UUID) {
        if pending?.id == id { pending = nil }
    }
}

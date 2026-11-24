import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RadioArtwork {
    static let maximumInputBytes = 2 * 1024 * 1024
    static let maximumThumbnailBytes = 128 * 1024

    static func stationIcon(from url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 5)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= maximumInputBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumInputBytes, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return thumbnail(data)
        } catch {
            return nil
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_000_000 / height else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= maximumThumbnailBytes else { return nil }
        return bytes as Data
    }
}

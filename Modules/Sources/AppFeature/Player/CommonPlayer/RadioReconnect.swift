import Foundation

struct RadioReconnect {
    private static let delays: [Duration] = [.seconds(5), .seconds(10), .seconds(20)]
    static let totalAttempts = delays.count
    static var finalResultDelay: Duration { delays[totalAttempts - 1] }

    private(set) var attempts = 0

    var delay: Duration? {
        Self.delays.indices.contains(attempts) ? Self.delays[attempts] : nil
    }

    mutating func recordAttempt() {
        if delay != nil { attempts += 1 }
    }

    mutating func reset() {
        attempts = 0
    }

    static func supports(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.pathExtension.lowercased() == "m3u8"
    }
}

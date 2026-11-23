import Foundation

struct RadioReconnect {
    private(set) var attempts = 0

    var delay: Duration? {
        switch attempts {
        case 0: .seconds(5)
        case 1: .seconds(10)
        case 2: .seconds(20)
        default: nil
        }
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

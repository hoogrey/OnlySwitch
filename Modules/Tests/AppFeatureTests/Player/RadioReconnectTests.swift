import Foundation
import Testing
@testable import AppFeature

struct RadioReconnectTests {
    @Test func backsOffAndStopsAfterThreeAttempts() {
        var recovery = RadioReconnect()
        for seconds in [5, 10, 20] {
            #expect(recovery.delay == .seconds(seconds))
            recovery.recordAttempt()
        }
        #expect(recovery.delay == nil)
    }

    @Test func resetRestoresTheRetryBudget() {
        var recovery = RadioReconnect()
        for _ in 0..<3 {
            recovery.recordAttempt()
        }
        recovery.reset()
        #expect(recovery.attempts == 0)
        #expect(recovery.delay == .seconds(5))
    }

    @Test(arguments: [
        ("http://radio.example/live.m3u8", true),
        ("https://radio.example/live.M3U8?token=abc", true),
        ("https://radio.example/live.mp3?playlist=index.m3u8", false),
        ("file:///tmp/local.m3u8", false)
    ])
    func recognizesRemoteHLSPlaylists(address: String, expected: Bool) throws {
        let url = try #require(URL(string: address))
        #expect(RadioReconnect.supports(url) == expected)
    }
}

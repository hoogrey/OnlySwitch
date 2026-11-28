import Testing
@testable import AppFeature

@MainActor
struct ScreenCleaningPermissionTests {
    @MainActor final class Effects {
        var allowed = false
        var active = false
        var checks = 0
        var help = 0
        var starts = 0
        var stops = 0
        var startError: ScreenCleaningError?

        var client: ScreenCleaningClient {
            ScreenCleaningClient(
                isAccessibilityAvailable: { self.checks += 1; return self.allowed },
                showPermissionHelp: { self.help += 1 },
                start: {
                    self.starts += 1
                    if let error = self.startError { throw error }
                    self.active = true
                },
                stop: { self.stops += 1; self.active = false },
                currentStatus: { self.active }
            )
        }
    }

    @Test func deniedStartShowsHelpAndThrowsWithoutStarting() async {
        let effects = Effects()
        let control = ScreenTestSwitch(client: effects.client)
        await #expect(throws: ScreenCleaningError.accessibilityUnavailable) {
            try await control.operateSwitch(isOn: true)
        }
        #expect(effects.checks == 1)
        #expect(effects.help == 1)
        #expect(effects.starts == 0)
        #expect(await control.currentStatus() == false)
    }

    @Test func allowedStartDoesNotShowHelp() async throws {
        let effects = Effects()
        effects.allowed = true
        let control = ScreenTestSwitch(client: effects.client)
        try await control.operateSwitch(isOn: true)
        #expect(effects.starts == 1)
        #expect(effects.help == 0)
        #expect(await control.currentStatus())
    }

    @Test func unavailableScreenPropagatesFailureWithoutChangingStatus() async {
        let effects = Effects()
        effects.allowed = true
        effects.startError = .screenUnavailable
        let control = ScreenTestSwitch(client: effects.client)

        await #expect(throws: ScreenCleaningError.screenUnavailable) {
            try await control.operateSwitch(isOn: true)
        }
        #expect(effects.checks == 1)
        #expect(effects.starts == 1)
        #expect(effects.help == 0)
        #expect(await control.currentStatus() == false)
    }

    @Test func stopAfterRevocationNeverChecksOrPrompts() async throws {
        let effects = Effects()
        effects.active = true
        let control = ScreenTestSwitch(client: effects.client)
        try await control.operateSwitch(isOn: false)
        #expect(effects.stops == 1)
        #expect(effects.checks == 0)
        #expect(effects.help == 0)
        #expect(await control.currentStatus() == false)
    }
}

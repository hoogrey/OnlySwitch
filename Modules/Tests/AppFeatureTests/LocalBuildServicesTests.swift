import AppKit
import Extensions
import Testing
@testable import AppFeature

struct LocalBuildServicesTests {
    @Test
    func localHelperReportsUnavailableForEveryOperation() async throws {
        let client = PrivilegedOperationClient.live(configuration: AppBuildConfiguration(isLocal: true))
        try #require(await client.status() == .unavailable)
        await #expect(throws: PrivilegedOperationClientError.unavailable) {
            try await client.installFromInteractiveUI()
        }
        await #expect(throws: PrivilegedOperationClientError.unavailable) {
            try await client.removeFromInteractiveUI()
        }
        await #expect(throws: PrivilegedOperationClientError.unavailable) {
            try await client.perform(.lowPowerMode, true)
        }
    }

    @Test @MainActor
    func localUpdaterSkipsProbesAndManualPresentation() async {
        let wasActive = NSApp?.isActive
        let updater = Updater(configuration: AppBuildConfiguration(isLocal: true))
        let duration = await ContinuousClock().measure {
            #expect(await updater.probeForUpdate() == .failed)
        }
        #expect(duration < .seconds(5))
        updater.showUpdateWindow()
        #expect(NSApp?.isActive == wasActive)
    }
}

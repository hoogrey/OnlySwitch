import ComposableArchitecture
import Testing
@testable import AppFeature

@MainActor
struct PermissionsHealthTests {
    @Test(arguments: [false, true])
    func observationsDoNotInventDenial(reported: Bool) {
        #expect(PermissionObservation(reportedAvailable: reported) ==
                (reported ? .reportedAvailable : .needsChecking))
    }

    @Test func initialStateHasNoObservation() {
        #expect(PermissionsHealthFeature.State().snapshot == nil)
    }

    @Test func refreshReadsAndReplacesObservationWithoutOpeningSettings() async {
        let first = PermissionsHealthSnapshot(accessibility: .reportedAvailable, screenRecording: .needsChecking)
        let second = PermissionsHealthSnapshot(accessibility: .needsChecking, screenRecording: .reportedAvailable)
        let readings = LockIsolated([first, second])
        let store = TestStore(initialState: PermissionsHealthFeature.State()) {
            PermissionsHealthFeature()
        } withDependencies: {
            $0.permissionsHealth.inspect = { readings.withValue { $0.removeFirst() } }
            $0.permissionsHealth.openSettings = { _ in
                Issue.record("Inspection must not open System Settings")
                return false
            }
        }
        await store.send(.refresh)
        await store.receive(.snapshotLoaded(first)) { $0.snapshot = first }
        await store.send(.refresh)
        await store.receive(.snapshotLoaded(second)) { $0.snapshot = second }
    }

    @Test(arguments: [PermissionSettingsDestination.accessibility, .screenRecording])
    func settingsFailureAndSuccessfulRetry(destination: PermissionSettingsDestination) async {
        let calls = LockIsolated<[PermissionSettingsDestination]>([])
        let store = TestStore(initialState: PermissionsHealthFeature.State()) {
            PermissionsHealthFeature()
        } withDependencies: {
            $0.permissionsHealth.openSettings = { destination in
                calls.withValue { $0.append(destination); return $0.count > 1 }
            }
        }
        await store.send(.openSettings(destination))
        await store.receive(.settingsOpened(false)) { $0.openingFailure = true }
        await store.send(.openSettings(destination))
        await store.receive(.settingsOpened(true)) { $0.openingFailure = false }
        #expect(calls.value == [destination, destination])
    }

    @Test func settingsDestinationsAreFixed() {
        #expect(PermissionSettingsDestination.accessibility.url.absoluteString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(PermissionSettingsDestination.screenRecording.url.absoluteString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}

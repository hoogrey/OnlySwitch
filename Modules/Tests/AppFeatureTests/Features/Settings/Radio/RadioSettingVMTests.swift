import Combine
import Foundation
import Testing
@testable import AppFeature

@MainActor
struct RadioSettingVMTests {
    enum Toggle: CaseIterable, Sendable {
        case waveform, stationNotification, trackNotification

        var viewModelKey: ReferenceWritableKeyPath<RadioSettingVM, Bool> {
            switch self {
            case .waveform: \.soundWaveEffectDisplay
            case .stationNotification: \.allowNotificationChangingStation
            case .trackNotification: \.allowNotificationTrack
            }
        }

        var preferencesKey: ReferenceWritableKeyPath<TestPreferences, Bool> {
            switch self {
            case .waveform: \.soundWaveEffectDisplay
            case .stationNotification: \.allNotificationChangingStation
            case .trackNotification: \.allNotificationTrack
            }
        }
    }

    @Test(arguments: Toggle.allCases)
    func togglePublishesImmediatelyAndUpdatesPreferences(_ toggle: Toggle) {
        let preferences = TestPreferences()
        let viewModel = RadioSettingVM(preferences: preferences, notificationCenter: NotificationCenter())
        let viewModelKey = toggle.viewModelKey
        let preferencesKey = toggle.preferencesKey
        var observedValues: [Bool] = []
        let subscription = viewModel.objectWillChange.sink {
            observedValues.append(preferences[keyPath: preferencesKey])
        }
        defer { subscription.cancel() }

        viewModel[keyPath: viewModelKey] = true
        #expect(observedValues == [false])
        #expect(preferences[keyPath: preferencesKey])
        #expect(viewModel[keyPath: viewModelKey])

        viewModel[keyPath: viewModelKey] = false
        #expect(observedValues == [false, true])
        #expect(!preferences[keyPath: preferencesKey])
        #expect(!viewModel[keyPath: viewModelKey])
    }

    @Test(arguments: [Toggle.stationNotification, .trackNotification])
    func enablingRequestsAuthorizationOnceAndDisablingDoesNot(_ toggle: Toggle) async {
        let preferences = TestPreferences()
        let recorder = RadioNotificationTests.Recorder()
        let viewModel = RadioSettingVM(preferences: preferences, notificationCenter: NotificationCenter(),
                                       notifications: recorder.client)
        viewModel[keyPath: toggle.viewModelKey] = true
        await viewModel.notificationAuthorizationTask?.value
        #expect(await recorder.authorizationRequests == 1)

        viewModel[keyPath: toggle.viewModelKey] = true
        viewModel[keyPath: toggle.viewModelKey] = false
        await viewModel.notificationAuthorizationTask?.value
        #expect(await recorder.authorizationRequests == 1)
        #expect(preferences[keyPath: toggle.preferencesKey] == false)
    }

    @Test func waveformDoesNotRequestNotificationAuthorization() async {
        let recorder = RadioNotificationTests.Recorder()
        let viewModel = RadioSettingVM(preferences: TestPreferences(), notificationCenter: NotificationCenter(),
                                       notifications: recorder.client)
        viewModel.soundWaveEffectDisplay = true
        #expect(viewModel.notificationAuthorizationTask == nil)
        #expect(await recorder.authorizationRequests == 0)
    }

    @Test(arguments: [Toggle.stationNotification, .trackNotification],
          [RadioNotificationTests.Outcome.denied, .authorizationFailure])
    func authorizationFailurePreservesEnabledPreference(
        _ toggle: Toggle, _ outcome: RadioNotificationTests.Outcome
    ) async {
        let preferences = TestPreferences()
        let recorder = RadioNotificationTests.Recorder(outcome: outcome)
        let viewModel = RadioSettingVM(preferences: preferences, notificationCenter: NotificationCenter(),
                                       notifications: recorder.client)
        viewModel[keyPath: toggle.viewModelKey] = true
        let authorized = await viewModel.notificationAuthorizationTask?.value
        #expect(authorized == false)
        #expect(preferences[keyPath: toggle.preferencesKey])
        #expect(await recorder.authorizationRequests == 1)
    }

    final class TestPreferences: RadioPlaybackPreferences {
        var soundWaveEffectDisplay = false
        var volume: Float = 1
        var allNotificationChangingStation = false
        var allNotificationTrack = false
    }
}

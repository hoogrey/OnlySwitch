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

    final class TestPreferences: RadioPlaybackPreferences {
        var soundWaveEffectDisplay = false
        var volume: Float = 1
        var allNotificationChangingStation = false
        var allNotificationTrack = false
    }
}

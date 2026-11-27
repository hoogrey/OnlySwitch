//
//  RadioSettingVM.swift
//  OnlySwitch
//
//  Created by Jacklandrin on 2021/12/9.
//

import Combine
import Extensions
import Foundation

@MainActor
protocol RadioPlaybackPreferences: AnyObject {
    var soundWaveEffectDisplay: Bool { get set }
    var volume: Float { get set }
    var allNotificationChangingStation: Bool { get set }
    var allNotificationTrack: Bool { get set }
}

extension Preferences: RadioPlaybackPreferences {}

/// Playback preferences shown above the station lists. Stations themselves live in `RadioStationsFeature`.
@MainActor
class RadioSettingVM: ObservableObject {
    @Published private var preferences: any RadioPlaybackPreferences
    private var cancellables = Set<AnyCancellable>()

    var soundWaveEffectDisplay: Bool {
        get {
            preferences.soundWaveEffectDisplay
        }
        set {
            objectWillChange.send()
            preferences.soundWaveEffectDisplay = newValue
        }
    }

    var sliderValue: Float {
        get {
            preferences.volume
        }
        set {
            preferences.volume = newValue
        }
    }

    var allowNotificationChangingStation: Bool {
        get {
            preferences.allNotificationChangingStation
        }
        set {
            objectWillChange.send()
            preferences.allNotificationChangingStation = newValue
        }
    }

    var allowNotificationTrack: Bool {
        get {
            preferences.allNotificationTrack
        }
        set {
            objectWillChange.send()
            preferences.allNotificationTrack = newValue
        }
    }

    convenience init() {
        let observer = PreferencesObserver.shared
        self.init(preferences: observer.preferences, notificationCenter: .default)
        observer.$preferences
            .dropFirst()
            .sink { [weak self] preferences in self?.preferences = preferences }
            .store(in: &cancellables)
    }

    init(preferences: any RadioPlaybackPreferences, notificationCenter: NotificationCenter) {
        self.preferences = preferences

        notificationCenter.publisher(for: .volumeChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

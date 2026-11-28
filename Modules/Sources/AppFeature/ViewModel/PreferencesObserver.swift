//
//  PreferencesPublisher.swift
//  OnlySwitch
//
//  Created by Jacklandrin on 2022/8/5.
//

import Foundation

@MainActor
class PreferencesObserver:ObservableObject {
    static let shared = PreferencesObserver()
    @Published var preferences = Preferences.shared

    private let playerAvailability: PlayerAvailabilityPreferences
    private let applyPlayerAvailability: @MainActor (PlayerType, Bool) -> Void
    private let notificationCenter: NotificationCenter

    init(
        playerAvailability: PlayerAvailabilityPreferences = .init(),
        applyPlayerAvailability: @escaping @MainActor (PlayerType, Bool) -> Void = { type, enabled in
            PlayerManager.shared.applyAvailabilityChange(for: type, enabled: enabled)
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.playerAvailability = playerAvailability
        self.applyPlayerAvailability = applyPlayerAvailability
        self.notificationCenter = notificationCenter
    }

    func isPlayerEnabled(_ type: PlayerType) -> Bool {
        playerAvailability.isEnabled(type)
    }

    func togglePlayerAvailability(_ type: PlayerType) {
        let enabled = !isPlayerEnabled(type)
        objectWillChange.send()
        playerAvailability.setEnabled(enabled, for: type)
        applyPlayerAvailability(type, enabled)
        notificationCenter.post(name: .changeSettings, object: nil)
    }
}

import Foundation
import Extensions

struct PlayerAvailabilityPreferences {
    var defaults: UserDefaults = .standard

    func isEnabled(_ type: PlayerType) -> Bool {
        switch type {
        case .Radio:
            storedValue(for: .Radio) ?? true
        case .BackNoises:
            storedValue(for: .BackNoises) ?? isEnabled(.Radio)
        }
    }

    func setEnabled(_ enabled: Bool, for type: PlayerType) {
        // Capture the previous shared setting before any radio-only change.
        if type == .Radio { migrateLegacyAvailability() }
        defaults.set(try? JSONEncoder().encode(enabled), forKey: key(for: type))
    }

    func migrateLegacyAvailability() {
        guard storedValue(for: .BackNoises) == nil else { return }
        setEnabled(isEnabled(.Radio), for: .BackNoises)
    }

    private func storedValue(for type: PlayerType) -> Bool? {
        guard let data = defaults.data(forKey: key(for: type)) else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }

    private func key(for type: PlayerType) -> String {
        switch type {
        case .Radio: UserDefaults.Key.radioEnable
        case .BackNoises: UserDefaults.Key.backNoisesEnable
        }
    }
}

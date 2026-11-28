import Extensions
import Foundation
import Testing
@testable import AppFeature

struct PlayerAvailabilityPreferencesTests {
    @Test(arguments: [PlayerType.Radio, .BackNoises])
    func disablingOneSourcePreservesTheOther(source: PlayerType) throws {
        let suite = "PlayerAvailabilityPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerAvailabilityPreferences(defaults: defaults)
        let otherSource: PlayerType = source == .Radio ? .BackNoises : .Radio

        #expect(preferences.isEnabled(source))
        #expect(preferences.isEnabled(otherSource))

        preferences.setEnabled(false, for: source)

        let reloaded = PlayerAvailabilityPreferences(defaults: defaults)
        #expect(reloaded.isEnabled(source) == false)
        #expect(reloaded.isEnabled(otherSource))

        preferences.setEnabled(false, for: otherSource)
        preferences.setEnabled(true, for: source)

        #expect(reloaded.isEnabled(source))
        #expect(reloaded.isEnabled(otherSource) == false)
        #expect(SettingsBackup.isExportablePreference(UserDefaults.Key.backNoisesEnable))
    }

    @Test func enablingLegacyRadioKeepsPreviouslyDisabledNoiseOff() throws {
        let suite = "PlayerAvailabilityPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(false), forKey: UserDefaults.Key.radioEnable)
        let preferences = PlayerAvailabilityPreferences(defaults: defaults)

        preferences.setEnabled(true, for: .Radio)

        #expect(preferences.isEnabled(.Radio))
        #expect(preferences.isEnabled(.BackNoises) == false)
        let persisted = try #require(defaults.data(forKey: UserDefaults.Key.backNoisesEnable))
        #expect(try JSONDecoder().decode(Bool.self, from: persisted) == false)
    }

    @Test func legacyMigrationPreservesAnExplicitBackgroundNoisePreference() throws {
        let suite = "PlayerAvailabilityPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(true), forKey: UserDefaults.Key.radioEnable)
        defaults.set(try JSONEncoder().encode(false), forKey: UserDefaults.Key.backNoisesEnable)
        let preferences = PlayerAvailabilityPreferences(defaults: defaults)

        preferences.migrateLegacyAvailability()

        #expect(preferences.isEnabled(.Radio))
        #expect(preferences.isEnabled(.BackNoises) == false)
    }
}

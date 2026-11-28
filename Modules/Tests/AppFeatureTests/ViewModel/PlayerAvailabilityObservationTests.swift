import Combine
import Defines
import Foundation
import Testing
@testable import AppFeature

@MainActor
struct PlayerAvailabilityObservationTests {
    @Test(arguments: [PlayerType.Radio, .BackNoises])
    func togglePublishesImmediatelyAndOnlyAppliesTheSelectedSource(source: PlayerType) throws {
        let suite = "PlayerAvailabilityObservationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerAvailabilityPreferences(defaults: defaults)
        let center = NotificationCenter()
        var affectedSources: [PlayerType] = []
        var appliedValues: [Bool] = []
        let observer = PreferencesObserver(
            playerAvailability: preferences,
            applyPlayerAvailability: { type, enabled in
                affectedSources.append(type)
                appliedValues.append(enabled)
            },
            notificationCenter: center
        )
        let otherSource: PlayerType = source == .Radio ? .BackNoises : .Radio
        var valuesBeforeChanges: [Bool] = []
        var valuesAtSettingsRefresh: [Bool] = []
        let observation = observer.objectWillChange.sink {
            valuesBeforeChanges.append(observer.isPlayerEnabled(source))
        }
        let refresh = center.publisher(for: .changeSettings).sink { _ in
            valuesAtSettingsRefresh.append(observer.isPlayerEnabled(source))
        }
        defer {
            observation.cancel()
            refresh.cancel()
        }

        observer.togglePlayerAvailability(source)

        #expect(observer.isPlayerEnabled(source) == false)
        #expect(observer.isPlayerEnabled(otherSource))
        #expect(valuesBeforeChanges == [true])
        #expect(valuesAtSettingsRefresh == [false])
        #expect(affectedSources == [source])
        #expect(appliedValues == [false])

        observer.togglePlayerAvailability(source)

        #expect(observer.isPlayerEnabled(source))
        #expect(observer.isPlayerEnabled(otherSource))
        #expect(valuesBeforeChanges == [true, false])
        #expect(valuesAtSettingsRefresh == [false, true])
        #expect(affectedSources == [source, source])
        #expect(appliedValues == [false, true])
    }
}

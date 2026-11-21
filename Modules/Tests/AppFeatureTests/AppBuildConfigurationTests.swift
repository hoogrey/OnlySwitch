import Extensions
import Foundation
import Testing

struct AppBuildConfigurationTests {
    @Test
    func onlyAPropertyListBooleanEnablesLocalMode() {
        let key = "OnlySwitchLocalMode"
        #expect(AppBuildConfiguration.from(infoDictionary: [key: true]).isLocal)
        #expect(!AppBuildConfiguration.from(infoDictionary: [:]).isLocal)
        #expect(!AppBuildConfiguration.from(infoDictionary: [key: false]).isLocal)
        #expect(!AppBuildConfiguration.from(infoDictionary: [key: "true"]).isLocal)
        #expect(!AppBuildConfiguration.from(infoDictionary: [key: "false"]).isLocal)
        #expect(!AppBuildConfiguration.from(infoDictionary: [key: NSNumber(value: 1)]).isLocal)
        let bundleConfiguration = AppBuildConfiguration.from(infoDictionary: Bundle.main.infoDictionary ?? [:])
        #expect(AppBuildConfiguration.current.isLocal == bundleConfiguration.isLocal)
    }

    @Test
    func schemesAndKeychainServicesReflectTheConfiguration() {
        let local = AppBuildConfiguration(isLocal: true)
        let official = AppBuildConfiguration(isLocal: false)
        #expect(local.urlScheme == "onlyswitch-local")
        #expect(official.urlScheme == "onlyswitch")

        let service = "OnlySwitch.Codex.ChatGPTSession"
        let scopedService = "local.OnlySwitch.OnlySwitch.Codex.ChatGPTSession"
        #expect(official.keychainService(service) == service)
        #expect(local.keychainService(service) == scopedService)
        #expect(local.keychainService(scopedService) == scopedService)
    }

    @Test
    func localSharedPreferencesUseOnlyTheSuppliedStandardDomain() throws {
        let prefix = "AppBuildConfigurationTests.\(UUID().uuidString)."
        let standardName = prefix + "standard"
        let sharedName = prefix + "OnlySwitch.shared"
        let standard = try #require(UserDefaults(suiteName: standardName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        defer {
            standard.removePersistentDomain(forName: standardName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let key = "isolationSentinel"
        shared.set("official", forKey: key)

        let local = AppBuildConfiguration(isLocal: true)
        let selected = try #require(local.sharedDefaults(appIdentifierPrefix: prefix, standard: standard))
        #expect(selected === standard)
        #expect(local.sharedDefaults(appIdentifierPrefix: "", requiresPrefix: true, standard: standard) === standard)
        #expect(selected.string(forKey: key) == nil)
        selected.set("local", forKey: key)
        #expect(standard.string(forKey: key) == "local")
        #expect(shared.string(forKey: key) == "official")

        let official = AppBuildConfiguration(isLocal: false)
        let group = try #require(official.sharedDefaults(appIdentifierPrefix: prefix, standard: standard))
        #expect(group.string(forKey: key) == "official")
        #expect(official.sharedDefaults(appIdentifierPrefix: "", requiresPrefix: true, standard: standard) == nil)
        #expect(official.sharedDefaults(appIdentifierPrefix: "", standard: standard) != nil)
    }
}

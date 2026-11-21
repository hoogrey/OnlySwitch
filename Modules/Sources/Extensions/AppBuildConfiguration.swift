import CoreFoundation
import Foundation

public struct AppBuildConfiguration: Sendable {
    public static let current = from(infoDictionary: Bundle.main.infoDictionary ?? [:])

    public let isLocal: Bool

    public init(isLocal: Bool) {
        self.isLocal = isLocal
    }

    public static func from(infoDictionary: [String: Any]) -> Self {
        guard let marker = infoDictionary["OnlySwitchLocalMode"] as? NSNumber,
              CFGetTypeID(marker) == CFBooleanGetTypeID() else {
            return Self(isLocal: false)
        }
        return Self(isLocal: marker.boolValue)
    }

    public var urlScheme: String {
        isLocal ? "onlyswitch-local" : "onlyswitch"
    }

    public func keychainService(_ service: String) -> String {
        let prefix = "local.OnlySwitch."
        guard isLocal, !service.hasPrefix(prefix) else { return service }
        return prefix + service
    }

    public func sharedDefaults(
        appIdentifierPrefix: String,
        requiresPrefix: Bool = false,
        standard: UserDefaults = .standard
    ) -> UserDefaults? {
        if isLocal { return standard }
        guard !requiresPrefix || !appIdentifierPrefix.isEmpty else { return nil }
        return UserDefaults(suiteName: "\(appIdentifierPrefix)OnlySwitch.shared")
    }
}

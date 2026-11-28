import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies

enum PermissionObservation: Equatable, Sendable {
    case reportedAvailable, needsChecking
    init(reportedAvailable: Bool) {
        self = reportedAvailable ? .reportedAvailable : .needsChecking
    }
}

struct PermissionsHealthSnapshot: Equatable, Sendable {
    var accessibility: PermissionObservation
    var screenRecording: PermissionObservation
}

enum PermissionSettingsDestination: Equatable, Sendable {
    case accessibility, screenRecording
    var url: URL {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

struct PermissionsHealthClient: Sendable {
    var inspect: @MainActor @Sendable () -> PermissionsHealthSnapshot
    var openSettings: @MainActor @Sendable (PermissionSettingsDestination) -> Bool
}

extension PermissionsHealthClient: DependencyKey {
    static let liveValue = Self(
        inspect: {
            PermissionsHealthSnapshot(
                accessibility: .init(reportedAvailable: AXIsProcessTrusted()),
                screenRecording: .init(reportedAvailable: CGPreflightScreenCaptureAccess())
            )
        },
        openSettings: { NSWorkspace.shared.open($0.url) }
    )
    static let testValue = Self(
        inspect: { .init(accessibility: .needsChecking, screenRecording: .needsChecking) },
        openSettings: { _ in false }
    )
}

extension DependencyValues {
    var permissionsHealth: PermissionsHealthClient {
        get { self[PermissionsHealthClient.self] }
        set { self[PermissionsHealthClient.self] = newValue }
    }
}

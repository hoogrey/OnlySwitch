import Foundation
import AppKit
import PureColorView
import SwiftUI
import Switches
import Extensions

enum ScreenCleaningError: Error, Equatable {
    case accessibilityUnavailable
    case screenUnavailable
}

struct ScreenCleaningClient {
    var isAccessibilityAvailable: @MainActor () -> Bool
    var showPermissionHelp: @MainActor () -> Void
    var start: @MainActor () throws -> Void
    var stop: @MainActor () -> Void
    var currentStatus: @MainActor () -> Bool
}

final class ScreenTestSwitch: SwitchProvider, CurrentScreen, @unchecked Sendable {
    static let shared = ScreenTestSwitch()
    var type: SwitchType = .screenTest
    var delegate: SwitchDelegate?
    private let client: ScreenCleaningClient

    init(client: ScreenCleaningClient? = nil) {
        self.client = client ?? .live
    }

    @MainActor func currentStatus() async -> Bool { client.currentStatus() }
    @MainActor func currentInfo() async -> String { "" }

    @MainActor func operateSwitch(isOn: Bool) async throws {
        guard isOn else {
            client.stop()
            return
        }
        guard client.isAccessibilityAvailable() else {
            client.showPermissionHelp()
            throw ScreenCleaningError.accessibilityUnavailable
        }
        try client.start()
    }

    func isVisible() -> Bool { true }
}

@MainActor
private final class ScreenCleaningRuntime: CurrentScreen {
    static let shared = ScreenCleaningRuntime()
    private var view: NSView?

    func start() throws {
        guard let screen = getScreenWithMouse() else { throw ScreenCleaningError.screenUnavailable }
        let view = NSHostingView(rootView: PureColorView {
            Task { try? await ScreenTestSwitch.shared.operateSwitch(isOn: false) }
        })
        guard view.enterFullScreenMode(screen) else { throw ScreenCleaningError.screenUnavailable }
        self.view = view
    }

    func stop() {
        view?.exitFullScreenMode()
        view = nil
    }

    var isActive: Bool { view != nil }
}

extension ScreenCleaningClient {
    static let live = Self(
        isAccessibilityAvailable: { AXIsProcessTrusted() },
        showPermissionHelp: {
            let alert = NSAlert()
            alert.messageText = "Screen cleaning permission required".localized()
            alert.informativeText = "Screen cleaning permission help".localized()
            alert.addButton(withTitle: "Open Accessibility Settings".localized())
            alert.addButton(withTitle: "Features & Permissions".localized())
            alert.addButton(withTitle: "Cancel".localized())
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !NSWorkspace.shared.open(PermissionSettingsDestination.accessibility.url) {
                    let error = NSAlert()
                    error.messageText = "Permission settings open failed".localized()
                    error.runModal()
                }
            case .alertSecondButtonReturn:
                SettingsVM.shared.selection = .PermissionsHealth
                SettingsWindow.shared.show()
            default: break
            }
        },
        start: { try ScreenCleaningRuntime.shared.start() },
        stop: { ScreenCleaningRuntime.shared.stop() },
        currentStatus: { ScreenCleaningRuntime.shared.isActive }
    )
}

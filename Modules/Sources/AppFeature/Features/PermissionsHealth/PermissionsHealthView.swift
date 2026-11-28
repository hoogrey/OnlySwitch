import SwiftUI
import ComposableArchitecture
import Extensions

struct PermissionsHealthView: View {
    let store: StoreOf<PermissionsHealthFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Permission status explanation".localized())
                    .foregroundStyle(.secondary)
                GroupBox("Screen Test".localized()) {
                    permissionRow("Accessibility".localized(), store.snapshot?.accessibility, .accessibility)
                }
                GroupBox("Dock Preview".localized()) {
                    VStack(spacing: 12) {
                        permissionRow("Accessibility".localized(), store.snapshot?.accessibility, .accessibility)
                        permissionRow("Screen Recording".localized(), store.snapshot?.screenRecording, .screenRecording)
                    }
                }
                Button("Recheck permissions".localized()) { store.send(.refresh) }
                if store.openingFailure {
                    Text("Permission settings open failed".localized())
                        .foregroundStyle(.red)
                }
                Text("Permission troubleshooting".localized())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { store.send(.refresh) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.send(.refresh)
        }
    }

    private func permissionRow(_ title: String, _ observation: PermissionObservation?, _ destination: PermissionSettingsDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Label(
                    (observation == .reportedAvailable ? "System reports access available" : "Permission needs checking").localized(),
                    systemImage: observation == .reportedAvailable ? "checkmark.circle" : "questionmark.circle"
                )
                .foregroundStyle(.secondary)
            }
            Button((destination == .accessibility ? "Open Accessibility Settings" : "Open Screen Recording Settings").localized()) {
                store.send(.openSettings(destination))
            }
        }
        .padding(8)
    }
}

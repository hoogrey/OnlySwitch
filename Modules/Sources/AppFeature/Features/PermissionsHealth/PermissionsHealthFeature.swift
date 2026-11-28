import ComposableArchitecture

@Reducer
struct PermissionsHealthFeature {
    @ObservableState
    struct State: Equatable {
        var snapshot: PermissionsHealthSnapshot?
        var openingFailure = false
    }
    enum Action: Equatable {
        case refresh
        case snapshotLoaded(PermissionsHealthSnapshot)
        case openSettings(PermissionSettingsDestination)
        case settingsOpened(Bool)
    }
    @Dependency(\.permissionsHealth) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .refresh:
                return .run { send in await send(.snapshotLoaded(client.inspect())) }
            case let .snapshotLoaded(snapshot):
                state.snapshot = snapshot
                return .none
            case let .openSettings(destination):
                return .run { send in await send(.settingsOpened(client.openSettings(destination))) }
            case let .settingsOpened(success):
                state.openingFailure = !success
                return .none
            }
        }
    }
}

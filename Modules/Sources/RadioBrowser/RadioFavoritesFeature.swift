import ComposableArchitecture
import Foundation

/// The user's saved stations: playback, manual add/edit, deletion and import/export.
@Reducer
public struct RadioFavoritesFeature {
    public enum LoadPhase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    @ObservableState
    public struct State: Equatable {
        public var favorites: [RadioFavorite] = []
        public var loadPhase: LoadPhase = .loading
        public var playback = RadioPlaybackStatus()
        public var filterText = ""
        @Presents public var editor: RadioStationEditorFeature.State?
        @Presents public var alert: AlertState<Action.Alert>?

        public init() {}

        public var stationTitle: String? {
            if playback.isPlaying || playback.previewingStationID != nil {
                return playback.title.isEmpty ? nil : playback.title
            }
            return favorites.first { $0.id == playback.currentID }?.name ?? favorites.first?.name
        }

        public var visibleFavorites: [RadioFavorite] {
            let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return favorites }
            return favorites.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.streamURL.localizedCaseInsensitiveContains(query)
            }
        }

        public func isCurrent(_ id: UUID) -> Bool {
            playback.previewingStationID == nil && playback.currentID == id
        }

        public func isPlaying(_ id: UUID) -> Bool {
            isCurrent(id) && playback.isPlaying
        }
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        case reload
        case favoritesLoaded([RadioFavorite])
        case loadFailed(RadioLibraryError)
        case addTapped
        case editTapped(UUID)
        case deleteTapped(UUID)
        case playTapped(UUID)
        case previousStationTapped
        case nextStationTapped
        case togglePlaybackTapped
        case copyURLTapped(UUID)
        case importTapped
        case exportTapped
        case saveFinished(Result<RadioMessage, RadioLibraryError>)
        case deleteFinished(Result<RadioMessage, RadioLibraryError>)
        case importFinished(Result<Int, RadioLibraryError>)
        case exportFinished(Result<Bool, RadioLibraryError>)
        case editor(PresentationAction<RadioStationEditorFeature.Action>)
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)

        public enum Alert: Equatable, Sendable {
            case confirmDelete(UUID)
        }

        @CasePathable
        public enum Delegate: Sendable {
            case favoritesChanged([RadioFavorite])
            case notify(RadioMessage)
        }
    }

    @Dependency(\.radioLibraryClient) private var library

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate, .alert(.dismiss):
                return .none

            case .reload:
                if case .failed = state.loadPhase { state.loadPhase = .loading }
                return .run { [library] send in
                    do {
                        await send(.favoritesLoaded(try await library.favorites()))
                    } catch {
                        await send(.loadFailed(RadioLibraryError(error)))
                    }
                }

            case let .favoritesLoaded(favorites):
                state.favorites = favorites
                state.loadPhase = .loaded
                return .send(.delegate(.favoritesChanged(favorites)))

            case let .loadFailed(error):
                state.loadPhase = .failed(error.message.text)
                return .send(.delegate(.notify(error.message)))

            case .addTapped:
                state.editor = RadioStationEditorFeature.State(mode: .add, existing: state.favorites)
                return .none

            case let .editTapped(id):
                guard let favorite = state.favorites.first(where: { $0.id == id }) else { return .none }
                state.editor = RadioStationEditorFeature.State(mode: .edit(favorite), existing: state.favorites)
                return .none

            case let .deleteTapped(id):
                guard let favorite = state.favorites.first(where: { $0.id == id }) else { return .none }
                guard state.favorites.count > 1 else {
                    return .send(.delegate(.notify(.atLeastOneStation)))
                }
                state.alert = AlertState {
                    TextState(verbatim: RadioStrings.deleteTitle(favorite.name))
                } actions: {
                    ButtonState(role: .destructive, action: .confirmDelete(id)) {
                        TextState(verbatim: RadioStrings.text("Radio Delete"))
                    }
                    ButtonState(role: .cancel) {
                        TextState(verbatim: RadioStrings.text("Radio Cancel"))
                    }
                } message: {
                    TextState(verbatim: RadioStrings.text("Radio Delete Station Message"))
                }
                return .none

            case let .alert(.presented(.confirmDelete(id))):
                guard let favorite = state.favorites.first(where: { $0.id == id }), state.favorites.count > 1 else { return .none }
                return .run { [library] send in
                    do {
                        try await library.delete(id)
                        await send(.deleteFinished(.success(.deleted(favorite.name))))
                    } catch {
                        await send(.deleteFinished(.failure(RadioLibraryError(error))))
                    }
                }

            case let .playTapped(id):
                guard state.favorites.contains(where: { $0.id == id }) else { return .none }
                return .run { @MainActor [library] _ in
                    let playback = library.playbackStatus()
                    if playback.previewingStationID == nil, playback.currentID == id {
                        library.togglePlayback()
                    } else {
                        library.play(id)
                    }
                }

            case .previousStationTapped:
                return moveStation(by: -1, favorites: state.favorites)

            case .nextStationTapped:
                return moveStation(by: 1, favorites: state.favorites)

            case .togglePlaybackTapped:
                return .run { @MainActor [library, favorites = state.favorites] _ in
                    let playback = library.playbackStatus()
                    if playback.isPlaying || playback.previewingStationID != nil
                        || favorites.contains(where: { $0.id == playback.currentID }) {
                        library.togglePlayback()
                    } else if let first = favorites.first {
                        library.play(first.id)
                    }
                }

            case let .copyURLTapped(id):
                guard let url = state.favorites.first(where: { $0.id == id })?.streamURL else { return .none }
                return .run { [library] _ in await library.copyToPasteboard(url) }

            case .importTapped:
                return .run { [library] send in
                    do {
                        if let count = try await library.importStations() {
                            await send(.importFinished(.success(count)))
                        }
                    } catch {
                        await send(.importFinished(.failure(.importFailed(error.localizedDescription))))
                    }
                }

            case .exportTapped:
                return .run { [library] send in
                    do {
                        await send(.exportFinished(.success(try await library.exportStations())))
                    } catch {
                        await send(.exportFinished(.failure(.exportFailed(error.localizedDescription))))
                    }
                }

            case let .editor(.presented(.delegate(.save(station, editingID)))):
                return .run { [library] send in
                    do {
                        if let editingID {
                            try await library.update(editingID, station)
                            await send(.saveFinished(.success(.saved(station.name))))
                        } else {
                            _ = try await library.add(station, nil, nil)
                            await send(.saveFinished(.success(.added(station.name))))
                        }
                    } catch {
                        await send(.saveFinished(.failure(RadioLibraryError(error))))
                    }
                }

            case let .saveFinished(.success(message)), let .deleteFinished(.success(message)):
                state.editor = nil
                return .concatenate(.send(.delegate(.notify(message))), .send(.reload))

            case let .saveFinished(.failure(error)), let .deleteFinished(.failure(error)),
                 let .importFinished(.failure(error)), let .exportFinished(.failure(error)):
                return .send(.delegate(.notify(error.message)))

            case let .importFinished(.success(count)):
                return .concatenate(.send(.delegate(.notify(.imported(count)))), .send(.reload))

            case let .exportFinished(.success(exported)):
                return exported ? .send(.delegate(.notify(.exported))) : .none

            case .editor:
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) { RadioStationEditorFeature() }
        .ifLet(\.$alert, action: \.alert)
    }

    private func moveStation(by offset: Int, favorites: [RadioFavorite]) -> Effect<Action> {
        guard favorites.count > 1 else { return .none }
        return .run { @MainActor [library] _ in
            let playback = library.playbackStatus()
            guard playback.previewingStationID == nil else { return }
            let current = favorites.firstIndex { $0.id == playback.currentID }
            let index = current.map { ($0 + offset + favorites.count) % favorites.count }
                ?? (offset > 0 ? 0 : favorites.count - 1)
            library.play(favorites[index].id)
        }
    }
}

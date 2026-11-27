import AppKit
import ComposableArchitecture
import RadioBrowser
import SwiftUI

struct RadioControlsTabView: View {
    let store: StoreOf<RadioStationsFeature>
    @StateObject private var settings = RadioSettingVM()

    var body: some View {
        WithPerceptionTracking {
            let favorites = store.favorites

            VStack(alignment: .leading, spacing: 14) {
                player(favorites)
                favoritesList(favorites)
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .task { await store.send(.task).finish() }
    }

    private func player(_ favorites: RadioFavoritesFeature.State) -> some View {
        let playback = favorites.playback
        let canStep = favorites.favorites.count > 1 && playback.previewingStationID == nil

        return VStack(alignment: .leading, spacing: 10) {
            Label(
                favorites.stationTitle ?? "Radio".localized(),
                systemImage: "radio"
            )
            .font(.headline)
            .lineLimit(1)

            if playback.previewingStationID != nil {
                Text(RadioStrings.text("Radio Previewing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(playback.phase.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)

            if playback.phase.canRetry, let sessionID = playback.sessionID {
                Button(RadioStrings.text("Radio Retry"), systemImage: "arrow.clockwise") {
                    store.send(.favorites(.retryPlaybackTapped(sessionID)))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !playback.streamInfo.isEmpty {
                Text(playback.streamInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                transportButton("Radio Previous Station", icon: "backward.end.fill", action: .previousStationTapped)
                    .disabled(!canStep)
                transportButton(
                    playback.isPlaying ? "Radio Stop" : "Radio Play",
                    icon: playback.isPlaying ? "stop.fill" : "play.fill",
                    action: .togglePlaybackTapped
                )
                .disabled(favorites.favorites.isEmpty && playback.previewingStationID == nil && !playback.isPlaying)
                transportButton("Radio Next Station", icon: "forward.end.fill", action: .nextStationTapped)
                    .disabled(!canStep)

                Spacer(minLength: 8)

                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                RadioVolumeSlider(volume: $settings.sliderValue, label: "Volume".localized())
                    .frame(maxWidth: 160)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RadioSettingsCard())
    }

    private func transportButton(
        _ key: String,
        icon: String,
        action: RadioFavoritesFeature.Action
    ) -> some View {
        let title = RadioStrings.text(key)
        return Button(title, systemImage: icon) { store.send(.favorites(action)) }
            .labelStyle(.iconOnly)
            .help(title)
    }

    private func favoritesList(_ favorites: RadioFavoritesFeature.State) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(RadioStrings.text("Radio Favorites"))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            switch favorites.loadPhase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case let .failed(detail):
                Text(detail)
                    .foregroundStyle(.secondary)
                Button(RadioStrings.text("Radio Retry")) { store.send(.favorites(.reload)) }
            case .loaded:
                if favorites.favorites.isEmpty {
                    Text(RadioStrings.text("Radio No Favorites"))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(favorites.favorites) { favorite in
                            favoriteButton(
                                favorite,
                                isCurrent: favorites.isCurrent(favorite.id),
                                isPlaying: favorites.isPlaying(favorite.id)
                            )
                        }
                    }
                }
            }
        }
    }

    private func favoriteButton(_ favorite: RadioFavorite, isCurrent: Bool, isPlaying: Bool) -> some View {
        Button {
            store.send(.favorites(.playTapped(favorite.id)))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "waveform" : (isCurrent ? "checkmark" : "star"))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(favorite.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.borderless)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 7))
        .accessibilityLabel(Text(favorite.name))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(Text(RadioStrings.text(isPlaying ? "Radio Stop" : "Radio Play")))
        .help(favorite.name)
    }
}

private struct RadioVolumeSlider: NSViewRepresentable {
    @Binding var volume: Float
    let label: String

    func makeNSView(context: Context) -> RadioVolumeSliderControl {
        RadioVolumeSliderControl(volume: $volume)
    }

    func updateNSView(_ slider: RadioVolumeSliderControl, context: Context) {
        slider.volume = $volume
        if slider.floatValue != volume {
            slider.floatValue = volume
        }
        slider.setAccessibilityLabel(label)
        slider.toolTip = label
    }
}

private final class RadioVolumeSliderControl: NSSlider {
    var volume: Binding<Float>

    init(volume: Binding<Float>) {
        self.volume = volume
        super.init(frame: .zero)
        minValue = 0
        maxValue = 1
        isContinuous = true
        target = self
        action = #selector(volumeChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RadioVolumeSliderControl requires a volume binding")
    }

    // Only Control allows dragging its window background. This control tracks its own drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func volumeChanged() {
        volume.wrappedValue = floatValue
    }
}

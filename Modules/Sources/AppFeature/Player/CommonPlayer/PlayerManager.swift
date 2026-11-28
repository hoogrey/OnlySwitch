//
//  File.swift
//  SpringRadio
//
//  Created by jack on 2020/4/19.
//  Copyright © 2020 jack. All rights reserved.
//

import Foundation

final class PlayerManager: @unchecked Sendable {
    static let shared = PlayerManager()
    var player:AudioPlayer!
    private var remoteCommandsConfigured = false
    
    var soundWaveEffectDisplay:Bool{
        Preferences.shared.soundWaveEffectDisplay
    }
    
    init() {
        
        self.player = MainActor.assumeIsolated { HostedAudioPlayer() }
        updateRemoteCommands()
        
        NotificationCenter.default.addObserver(forName: .soundWaveToggle, object: nil, queue: .main, using: { [self] _ in
            
            let currentPlayerItem = self.player.currentPlayerItem
            
            self.player.currentPlayerItem?.isPlaying = false
            self.player.clearCommandCenter()
            self.remoteCommandsConfigured = false
            
            self.player = MainActor.assumeIsolated { HostedAudioPlayer() }
            self.player.currentPlayerItem = currentPlayerItem
            
            self.updateRemoteCommands()
        })
    }

    @MainActor
    func applyAvailabilityChange(for type: PlayerType, enabled: Bool) {
        if enabled {
            if remoteCommandsConfigured, let item = player.currentPlayerItem,
               item.type == type, !item.isPlaying {
                player.setupNowPlaying()
                player.pauseCommandCenter()
            }
        } else {
            let item: CommonPlayerItem
            switch type {
            case .Radio:
                item = RadioStationSwitch.shared.playerItem
            case .BackNoises:
                item = BackNoisesTrackManager.shared.currentBackNoisesItem
            }
            // A noise download can have playback intent before it becomes the current item.
            if item.isPlaying { item.isPlaying = false }
            if player.currentPlayerItem === item {
                player.clearNowPlaying()
            }
        }
        updateRemoteCommands()
    }

    private func updateRemoteCommands() {
        let shouldConfigure = Preferences.shared.radioEnable || Preferences.shared.backNoisesEnable
        guard shouldConfigure != remoteCommandsConfigured else { return }
        remoteCommandsConfigured = shouldConfigure
        if shouldConfigure {
            player.setupRemoteCommandCenter()
        } else {
            player.clearCommandCenter()
        }
    }
}

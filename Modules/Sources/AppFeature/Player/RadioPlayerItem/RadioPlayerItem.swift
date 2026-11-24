//
//  RadioPlayerItem.swift
//  OnlySwitch
//
//  Created by Jacklandrin on 2022/7/6.
//

import Foundation
import Switches
import OnlySwitchPersistence

struct RadioPlayerItem {
    var isPlaying:Bool = false
    var title:String = ""
    {
        willSet {
            guard title != newValue else {return}
            if isPlaying &&
                !newValue.isEmpty &&
                Preferences.shared.allNotificationChangingStation {
                nowPlayingNotify(content: newValue, subtitle: "")
            }
        }
    }
    
    var artworkURL: URL?
    var streamUrl:String = ""
    var streamInfo:String = ""
    {
        willSet {
            guard streamInfo != newValue else {return}
            if isPlaying &&
                !newValue.isEmpty &&
                !title.isEmpty &&
                Preferences.shared.allNotificationTrack {
                nowPlayingNotify(content: title, subtitle: newValue)
            }
        }
    }
    
    var isEditing:Bool = false
    var id:UUID
    
    mutating func updateItem(radio:RadioStations) {
        self.id = radio.id!
        self.title = radio.title!
        self.artworkURL = radio.favicon.flatMap(URL.init(string:))
        self.streamUrl = radio.url!
        self.streamInfo = ""
    }

    func nowPlayingNotify(content:String, subtitle:String) {
        Task { @MainActor in
            let _ = try? await displayNotificationCMD(title: "Now Playing".localized(),
                                                      content: content,
                                                      subtitle: subtitle)
                .runAppleScript()
        }
    }
}

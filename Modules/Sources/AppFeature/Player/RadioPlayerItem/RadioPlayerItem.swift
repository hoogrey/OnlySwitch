//
//  RadioPlayerItem.swift
//  OnlySwitch
//
//  Created by Jacklandrin on 2022/7/6.
//

import Foundation
import Dependencies
import OnlySwitchPersistence

struct RadioPlayerItem {
    var isPlaying:Bool = false
    var title:String = ""
    
    var artworkURL: URL?
    var streamUrl:String = ""
    var streamInfo:String = ""
    {
        willSet {
            @Dependency(\.radioNotification) var client
            client.trackChanged(station: title, previousTrack: streamInfo, track: newValue,
                                isPlaying: isPlaying, enabled: Preferences.shared.allNotificationTrack)
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

}

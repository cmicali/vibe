//
//  Vibe-Bridging-Header.h
//  Vibe (macOS)
//
//  What the target's Swift can see of its own Objective-C. Swift is here for
//  the widget only — telling WidgetKit a snapshot is stale, and the bodies of
//  its App Intents (System/VibeWidgetIntents.swift) — so this stays at the
//  headers those bodies drive: the app delegate that owns the player
//  controller and the launch waiter, the transport the buttons reach, and
//  NSURL's pathKey, which a seek must present. It is not a place to start
//  moving the app into Swift.
//

#import "AppDelegate.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "MainPlayerController.h"
#import "NSURL+Hash.h"
#import "PlaylistController.h"

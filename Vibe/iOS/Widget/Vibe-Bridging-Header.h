//
//  Vibe-Bridging-Header.h
//  Vibe (iOS)
//
//  What the target's Swift can see of its own Objective-C. Swift is here for
//  two things only — telling WidgetKit a snapshot is stale, and the widget's
//  App Intents — so this stays at the headers those need: the controller the
//  intents drive, the scene that owns it, and the publisher whose track key a
//  seek must present. AudioTrack is here only so Swift can see the type of
//  PlaybackController.displayedTrack, which the controller's header forward-
//  declares. It is not a place to start moving the app into Swift.
//

#import "AudioTrack.h"
#import "PlaybackController.h"
#import "VibeiOSSceneDelegate.h"
#import "WidgetPublisher.h"

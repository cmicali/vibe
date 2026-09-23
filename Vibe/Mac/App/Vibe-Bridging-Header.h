//
//  Vibe-Bridging-Header.h
//  Vibe (macOS)
//
//  What the target's Swift can see of its own Objective-C: the widget's
//  transport entry point, and nothing else. Swift is here only for the bodies
//  of the widget's App Intents (System/VibeWidgetIntents.swift). TRAP: every
//  header named here must be Foundation-only — one that reaches AppKit gives
//  that file AppKit and AppIntents together, whose cross-import overlay links
//  all of SwiftUI into the app (see that file's trap).
//

#import "WidgetPublisher.h"

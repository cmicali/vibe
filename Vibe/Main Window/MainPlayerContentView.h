//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class GlyphButton;
@class ArtworkImageView;
@class AudioWaveformView;

NS_ASSUME_NONNULL_BEGIN

// The main window's whole UI (previously MainPlayerWindow.xib): builds
// artwork, waveform, transport buttons, track labels, and the playlist table,
// exposing them for the controller to drive. The view itself is transparent —
// the window's Liquid Glass backdrop (NSGlassEffectView, installed by
// MainPlayerController behind this view) provides the background.
// Button/menu actions are sent to `target` (the controller). The view is
// pinned at its design width (flexible right margin) so the window can widen
// past it to reveal the pitch panel.
@interface MainPlayerContentView : NSView

- (instancetype)initWithTarget:(id)target;

@property (readonly) GlyphButton *closeButton;
@property (readonly) GlyphButton *minimizeButton;
@property (readonly) GlyphButton *playButton;
@property (readonly) GlyphButton *nextButton;

// Tint wash over the header's glass panel; the artwork controller sets its
// layer background to the current track's dominant art color. A plain view
// rather than the glass's own tintColor because NSGlassEffectView drops its
// tint entirely while the window is inactive — this wash dims to half
// instead (ArtworkDisplayController).
@property (readonly) NSView *headerTintView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) AudioWaveformView *waveformView;

@property (readonly) NSTextField *artistTextField;
@property (readonly) NSTextField *titleTextField;
@property (readonly) NSTextField *totalTimeTextField;
@property (readonly) NSTextField *currentTimeTextField;
@property (readonly) NSTextField *fileMetadataTextField;
@property (readonly) NSTextField *bpmTextField;

@property (readonly) NSTableView *playlistTableView;

@end

NS_ASSUME_NONNULL_END

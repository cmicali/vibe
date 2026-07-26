//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class SymbolButton;
@class ArtworkImageView;
@class AudioWaveformView;
@class PlaylistTableView;

NS_ASSUME_NONNULL_BEGIN

// The main window's whole UI: builds artwork, waveform, transport buttons,
// track labels, and the playlist table,
// exposing them for the controller to drive. The view itself is transparent —
// the window's Liquid Glass backdrop (NSGlassEffectView, installed by
// MainPlayerController behind this view) provides the background.
// Button/menu actions are sent to `target` (the controller). The view is
// pinned at its design width (flexible right margin) so the window can widen
// past it to reveal the pitch panel.
@interface MainPlayerContentView : NSView

- (instancetype)initWithTarget:(id)target;

// Fired from the effective-appearance funnel (after the view's own
// material/tint updates) so appearance-dependent state owned elsewhere —
// the header art tint (ArtworkDisplayController) — can re-derive.
@property (nonatomic, copy, nullable) void (^appearanceChangedHandler)(void);

// Only the buttons the controller drives (symbol/enabled state) are exposed;
// the traffic lights and playlist toggle are fully self-contained (action
// wired at build, hover fade internal) and stay private to the view.
@property (readonly) SymbolButton *playButton;
@property (readonly) SymbolButton *nextButton;

// Tint wash over the header's glass panel; the artwork controller sets its
// layer background to the current track's dominant art color. A plain view
// rather than the glass's own tintColor because NSGlassEffectView drops its
// tint entirely while the window is inactive — the wash must not change
// with key state (ArtworkDisplayController).
@property (readonly) NSView *headerTintView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) AudioWaveformView *waveformView;

@property (readonly) NSTextField *artistTextField;
@property (readonly) NSTextField *titleTextField;
@property (readonly) NSTextField *totalTimeTextField;
@property (readonly) NSTextField *currentTimeTextField;
// Empty-state hint ("Drop a file or press ⌘O"); shown only while no track
// is loaded.
@property (readonly) NSTextField *dropHintTextField;
@property (readonly) NSTextField *fileMetadataTextField;
@property (readonly) NSTextField *bpmTextField;

@property (readonly) PlaylistTableView *playlistTableView;

@end

NS_ASSUME_NONNULL_END

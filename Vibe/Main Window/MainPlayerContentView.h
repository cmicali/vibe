//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class SymbolButton;
@class ArtworkImageView;
@class AudioWaveformView;
@class PlaylistTableView;
@class PlaylistDropZoneView;

NS_ASSUME_NONNULL_BEGIN

// The main window's whole UI. It builds the artwork, waveform, transport
// buttons, track labels and playlist table, and exposes them for the
// controller to drive. The view itself is transparent: the window's Liquid
// Glass backdrop, an NSGlassEffectView that MainPlayerController installs
// behind this view, provides the background. Button and menu actions are sent
// to `target`, the controller. The view is pinned at its design width, with a
// flexible right margin, so that the window can widen past it to reveal the
// pitch panel.
@interface MainPlayerContentView : NSView

- (instancetype)initWithTarget:(id)target;

// Fires from the effective-appearance funnel, after the view's own material
// and tint updates, so that appearance-dependent state owned elsewhere — the
// header art tint, in ArtworkDisplayController — can re-derive itself.
@property (nonatomic, copy, nullable) void (^appearanceChangedHandler)(void);

// Only the buttons the controller drives, through their symbol and enabled
// state, are exposed. The traffic lights and the playlist toggle are entirely
// self-contained — their action is wired at build and their hover fade is
// internal — so they stay private to the view.
@property (readonly) SymbolButton *playButton;
@property (readonly) SymbolButton *nextButton;

// The tint wash over the header's glass panel. The artwork controller sets its
// layer background to the current track's dominant art color. It is a plain
// view rather than the glass's own tintColor, because NSGlassEffectView drops
// its tint entirely while the window is inactive, and the wash must not change
// with key state; see ArtworkDisplayController.
@property (readonly) NSView *headerTintView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) AudioWaveformView *waveformView;

@property (readonly) NSTextField *artistTextField;
@property (readonly) NSTextField *titleTextField;
@property (readonly) NSTextField *totalTimeTextField;
@property (readonly) NSTextField *currentTimeTextField;
// The empty-state hint, "Drop a file or press ⌘O", shown only while no track
// is loaded.
@property (readonly) NSTextField *dropHintTextField;
@property (readonly) NSTextField *fileMetadataTextField;
@property (readonly) NSTextField *bpmTextField;

@property (readonly) PlaylistTableView *playlistTableView;
// The drop-target UI spanning the playlist pane: the empty-state hint and the
// drag-over wells. It is built hidden. The controller drives it from the
// updateUI funnel, on playlistEmpty and the launch grace, and forwards the
// window's drag-over events.
@property (readonly) PlaylistDropZoneView *playlistDropZoneView;

// Re-caps the artist line's width so that it truncates clear of the codec
// line's text rather than running under it. The view calls this itself on every
// resize; TrackDisplayController calls it whenever the codec line's content
// changes, since the clearance depends on how wide that text renders.
- (void)layoutArtistLineClearOfCodecLine;

@end

NS_ASSUME_NONNULL_END

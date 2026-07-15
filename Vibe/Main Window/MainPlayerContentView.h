//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class GlyphButton;
@class ArtworkImageView;
@class BackgroundArtworkImageView;
@class AudioWaveformView;

NS_ASSUME_NONNULL_BEGIN

// The main window's whole UI (previously MainPlayerWindow.xib): a
// behind-window blur that builds artwork, waveform, transport buttons, track
// labels, and the playlist table, exposing them for the controller to drive.
// Button/menu actions are sent to `target` (the controller). The view is
// pinned at its design width (flexible right margin) so the window can widen
// past it to reveal the pitch panel.
@interface MainPlayerContentView : NSVisualEffectView

- (instancetype)initWithTarget:(id)target;

@property (readonly) GlyphButton *closeButton;
@property (readonly) GlyphButton *minimizeButton;
@property (readonly) GlyphButton *playButton;
@property (readonly) GlyphButton *nextButton;

@property (readonly) BackgroundArtworkImageView *backgroundAlbumArtImageView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) NSView *albumArtGradientView;
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

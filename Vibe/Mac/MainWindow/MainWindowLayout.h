//
// Created by Christopher Micali on 7/15/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// The main window's layout constants, shared by MainWindow, for frame and
// minimum and maximum sizing, and MainPlayerContentView, for the design-time
// layout, so that the two cannot drift apart. Two Controls views read the
// radius and the artwork exclusion band, which are facts about this window's
// shape. Timing that any window uses is Util/WindowAnimation.h instead.
//
// Plain scalars, so static-in-header — one private copy per importer — is fine.

#import <Foundation/Foundation.h>

// The design and default width of the main content body: the player, with the
// pitch panel excluded. The window opens this wide on a first launch, and
// every subview frame in MainPlayerContentView is authored at this width. From
// there the user resizes freely, and the autosaved frame restores their width.
static const CGFloat kMainWindowContentWidth = 680;

// The narrowest the content body may be dragged. Below this the header's
// right-aligned codec and BPM readouts start crowding the title, and the
// waveform stops being worth reading.
static const CGFloat kMainWindowMinContentWidth = 480;

// The wide end of View > Size. All three presets are body widths only: small
// is the drag floor, default the design width, and large 1.75 times that. A
// preset therefore never disturbs the height the user, or the playlist toggle,
// has chosen.
static const CGFloat kMainWindowLargeContentWidth = kMainWindowContentWidth * 1.75;

// The corner radius of the main window, shared by the contentView layer mask
// in MainWindow, which is the one that actually shapes the window, the Liquid
// Glass backdrop, the header glass panel and its tint layer, and the pitch
// panel's right-edge corners. 20pt is the macOS 27 standardized window radius;
// Tahoe used 26.
static const CGFloat kMainWindowCornerRadius = 20;

// The player-only height, with the playlist collapsed. Anything taller than
// this is a large-layout window, meaning the playlist is showing.
static const CGFloat kMainWindowSmallHeight = 150;

// The default playlist-shown height, which is what the toggle opens to. A
// manual drag-resize may restore something taller, since the window has no
// maximum height beyond what the screen allows.
static const CGFloat kMainWindowLargeHeight = 400;

// The playlist pane's own floor, the pane being everything below the
// kMainWindowSmallHeight player band. Under roughly this the pane is a sliver
// rather than a playlist, and the empty state shows it worst: the drop well
// runs out of room for the two lines of text inside it, and then vanishes
// altogether at PlaylistDropZoneView's visibility floor, leaving a blank strip.
static const CGFloat kPlaylistPaneMinHeight = 100;

// The shortest playlist-shown window: the player band plus a pane worth
// showing. The window has no resting height between kMainWindowSmallHeight and
// this, and MainWindow snaps a drag across the band.
static const CGFloat kMainWindowMinLargeHeight = kMainWindowSmallHeight + kPlaylistPaneMinHeight;

// The design-time content height. Every subview frame in
// MainPlayerContentView is authored at kMainWindowContentWidth by this, and
// autoresizing stretches it to the user's window size. It is also the window's
// first-launch height, before loadSettings reconciles the persisted playlist
// and pitch-panel flags.
static const CGFloat kMainWindowDesignHeight = 350;

// The band at the bottom of the album art, in points from the art view's
// bottom edge, where a mouse-down must not start ArtworkImageView's drag-out.
// The transport SymbolButtons that MainPlayerContentView lays over the art's
// lower edge live there. Their frames set the real hit targets, and this is
// the band in which a press visually reads as aimed at the buttons. It is
// shared, so that the exclusion and the transport layout cannot drift apart.
static const CGFloat kArtworkTransportExclusionHeight = 42;

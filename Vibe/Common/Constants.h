//
// Created by Christopher Micali on 7/15/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// Window-layout constants shared by MainWindow (frame/min/max sizing) and
// MainPlayerContentView (design-time layout), so the two can't drift apart.
// Plain scalar constants, so static-in-header (one private copy per importer)
// is fine.

#import <Foundation/Foundation.h>

// Design/default width of the main content body (the player, pitch panel
// excluded). The window opens this wide on a first launch and every subview
// frame in MainPlayerContentView is authored at this width; from there the
// user resizes freely and the autosaved frame restores their width.
static const CGFloat kMainWindowContentWidth = 680;

// Narrowest the content body may be dragged. Below this the header's
// right-aligned codec/BPM readouts start crowding the title, and the waveform
// stops being worth reading.
static const CGFloat kMainWindowMinContentWidth = 480;

// The wide end of View > Size. The three presets are body widths only —
// small is the drag floor, default the design width, large 1.75× that — so a
// preset never disturbs the height the user (or the playlist toggle) chose.
static const CGFloat kMainWindowLargeContentWidth = kMainWindowContentWidth * 1.75;

// Corner radius of the main window, shared by the contentView layer mask
// (MainWindow — the one that actually shapes the window), the Liquid Glass
// backdrop, the header glass panel and tint layer, and the pitch panel's
// right-edge corners. 20pt is the macOS 27 standardized window radius
// (Tahoe used 26).
static const CGFloat kMainWindowCornerRadius = 20;

// Player-only height (playlist collapsed). Anything taller than this is a
// "large layout" window — the playlist is showing.
static const CGFloat kMainWindowSmallHeight = 150;

// Default playlist-shown height (what the toggle opens to); a manual
// drag-resize may restore taller — the window has no maximum height beyond
// what the screen allows.
static const CGFloat kMainWindowLargeHeight = 400;

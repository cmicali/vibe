//
// Created by Christopher Micali on 7/15/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// Window-layout constants shared by MainWindow (frame/min/max sizing) and
// MainPlayerContentView (design-time layout), so the two can't drift apart.
// Plain scalar constants, so static-in-header (one private copy per importer)
// is fine.

#import <Foundation/Foundation.h>

// Width of the main content; the window is this wide, plus kPitchPanelWidth
// when the pitch panel is revealed.
static const CGFloat kMainWindowContentWidth = 680;

// Corner radius of the main window, shared by the contentView layer mask
// (MainWindow — the one that actually shapes the window), the Liquid Glass
// backdrop, the header glass panel and tint layer, and the pitch panel's
// right-edge corners. 20pt is the macOS 27 standardized window radius
// (Tahoe used 26).
static const CGFloat kMainWindowCornerRadius = 20;

// Player-only height (playlist collapsed). Anything taller than this is a
// "large layout" window — the playlist is showing.
static const CGFloat kMainWindowSmallHeight = 150;

// Default playlist-shown height; a manual drag-resize may restore taller,
// up to kMainWindowMaxHeight.
static const CGFloat kMainWindowLargeHeight = 400;

static const CGFloat kMainWindowMaxHeight = 600;

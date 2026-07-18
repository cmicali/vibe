//
// Created by Christopher Micali on 7/18/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

// Shared base for the artwork image views (foreground art + blurred
// backdrop): layer-backed so setImage: can cross-fade the incoming image
// over the outgoing one, and opted out of drag-and-drop so file drops fall
// through to the window.
@interface CrossfadingImageView : NSImageView

@end

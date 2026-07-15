//
// Created by Christopher Micali on 7/8/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//
// Shared overlay cross-fade for the artwork image views.
//
// Why not a CATransition on the backing layer: NSImageView redraws into its
// layer on AppKit's own display schedule, so a transition added at setImage:
// time is not reliably in the same CA transaction as the contents change and
// silently no-ops. Why not a view snapshot (cacheDisplayInRect:): NSImageView
// draws via updateLayer, so the drawRect-based snapshot comes back BLANK and
// the fade is invisible. Instead the overlay is built directly from the
// outgoing NSImage itself, stacked on top while the new image renders
// beneath, and explicitly faded out — nothing here depends on AppKit's
// drawing path or transaction timing.

#import <AppKit/AppKit.h>

extern const NSTimeInterval kVibeArtCrossfadeDuration;

extern NSString *const kVibeCrossfadeOverlayName;

// Call BEFORE [super setImage:]: overlays the outgoing image and fades it
// out over the incoming one. No-ops when the view isn't on screen yet or has
// nothing to fade from.
void VibeBeginImageCrossfade(NSImageView *view);

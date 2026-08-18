//
//  EqualizerActivityRules.h
//  Vibe
//
//  The complete fail-closed decision for whether an indicator may consume
//  audio and run its snapshot poller. Platform code owns the meaning of
//  presentationVisible: it combines row visibility with its window, scene,
//  tab, card, and occlusion state before handing that fact to the control.
//

#import <Foundation/Foundation.h>

typedef struct {
    BOOL audioOutputActive;
    BOOL presentationVisible;
    BOOL attachedToWindow;
    BOOL hasLevelSource;
    BOOL hasRenderableArea;
} VibeEqualizerActivityState;

static inline BOOL VibeEqualizerShouldRun(VibeEqualizerActivityState state) {
    return state.audioOutputActive
        && state.presentationVisible
        && state.attachedToWindow
        && state.hasLevelSource
        && state.hasRenderableArea;
}

// Audio loss alone leaves visible pixels that can release to dots. Every other
// failed gate means the animation would be invisible or based on stale ownership.
static inline BOOL VibeEqualizerCanAnimateReleaseToDots(
        VibeEqualizerActivityState state) {
    return !state.audioOutputActive
        && state.presentationVisible
        && state.attachedToWindow
        && state.hasLevelSource
        && state.hasRenderableArea;
}

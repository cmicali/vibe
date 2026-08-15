//
//  WindowAnimation.h
//  Vibe
//
//  Window-chrome animation timing, shared by every window the app resizes
//  itself. It has no feature — the main window and the settings window both
//  use it — which is why it is here rather than beside either of them.
//

#import <Foundation/Foundation.h>

// Every resize the app performs itself — the main window's playlist toggle,
// pitch panel reveal and View > Size presets, and the settings window's
// tab-switch resize — runs at this one duration: the main window through its
// animationResizeTime: override, the settings window through its tab-switch
// NSAnimationContext. AppKit's default scales with the distance, at roughly
// 0.2s per 150pt, which makes larger jumps drag. These are chrome snapping to
// a new shape rather than content transitions, so a short fixed time reads
// better and stays consistent whatever the distance.
static const NSTimeInterval kWindowResizeAnimationDuration = 0.12;

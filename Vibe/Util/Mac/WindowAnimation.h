//
//  WindowAnimation.h
//  Vibe
//
//  Here because both the main and Settings windows use it.
//

#import <Foundation/Foundation.h>

// Every resize the app performs itself runs at this duration, rather than
// AppKit's distance-scaled default, which makes large jumps drag.
static const NSTimeInterval kWindowResizeAnimationDuration = 0.12;

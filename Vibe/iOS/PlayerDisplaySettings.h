//
//  PlayerDisplaySettings.h
//  Vibe (iOS)
//
//  iOS-owned keys, not AppSettings: on macOS these are AppTheme fields, and a
//  key whose mac counterpart is a theme field cannot be an AppSettings property
//  without lying. The waveform style has no such counterpart and stays there.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main after a settings screen writes any display setting, the
// waveform style included; the keep-alive card is the receiver. The time
// label's own tap repaints the pages itself and does not post.
extern NSNotificationName const VibeDisplaySettingsDidChangeNotification;

// Every display-setting writer ends on this, never a hand-composed post.
void VibeNotifyDisplaySettingsChanged(void);

// The right time label: NO (default) shows the duration, YES the
// minus-prefixed remaining time. Every render path goes through
// VibeRightTimeText.
BOOL VibeShowsRemainingTime(void);
void VibeSetShowsRemainingTime(BOOL remaining);

// The codec line under the artist, the tempo after it when known; on by
// default, as on the mac.
BOOL VibeShowsFileInfo(void);
void VibeSetShowsFileInfo(BOOL show);

// The shuffle and repeat buttons flanking the card's transport row; on by
// default. Hidden, both modes are off and CarPlay offers neither
// (PlaybackController.pushTransportModes).
BOOL VibeShowsShuffleRepeat(void);
void VibeSetShowsShuffleRepeat(BOOL show);

NS_ASSUME_NONNULL_END

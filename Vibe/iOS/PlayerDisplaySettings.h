//
//  PlayerDisplaySettings.h
//  Vibe (iOS)
//
//  How a display setting's change reaches the card. The settings themselves
//  are AppSettings properties (showRemainingTime, showFileInfo,
//  showShuffleRepeat, waveformStyle).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main after a settings screen writes any display setting, the
// waveform style included; the keep-alive card is the receiver. The time
// label's own tap repaints the pages itself and does not post.
extern NSNotificationName const VibeDisplaySettingsDidChangeNotification;

// Every display-setting writer ends on this, never a hand-composed post.
void VibeNotifyDisplaySettingsChanged(void);

NS_ASSUME_NONNULL_END

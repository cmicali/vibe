//
//  PlayerDisplaySettings.h
//  Vibe (iOS)
//
//  What the now-playing card draws rather than what it plays: the two
//  preferences the settings screen and the card both read, and the one
//  notification a write to either posts.
//
//  These are iOS-owned NSUserDefaults keys, beside FolderSession's and the
//  waveform zoom's, rather than AppSettings' equivalents: those sit inside its
//  macOS-only block, and they are there because they are read on every
//  playback tick and ride the hot cache that block exists for. The waveform
//  style is deliberately NOT here — both platforms draw waveforms, so it is a
//  shared AppSettings property.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main after the settings screen writes any display setting,
// including the waveform style. The card is built once and never torn down, so
// it is the receiver: a setting changed on the Playlist tab has to reach a
// screen sitting minimized behind it. The time label's own tap does not post —
// it repaints the pages itself.
extern NSNotificationName const VibeDisplaySettingsDidChangeNotification;

// The right-hand time label's mode, and the one place the two spellings live.
// NO — the default, and the macOS default — shows the track's total duration;
// YES shows the minus-prefixed remaining time ("-1:50"). Tapping the label
// toggles it, as it does on the mac. Every render path goes through
// VibeRightTimeText so a scrub, a tick and a page at rest cannot disagree.
BOOL VibeShowsRemainingTime(void);
void VibeSetShowsRemainingTime(BOOL remaining);

// Whether the card's header draws the file-format readout — codec, bitrate,
// sample rate — under the artist. The mac's Settings > Appearance > Show file
// info, and its default: on. There is no BPM/key line to go with it here,
// since analysis is macOS-only.
BOOL VibeShowsFileInfo(void);
void VibeSetShowsFileInfo(BOOL show);

NS_ASSUME_NONNULL_END

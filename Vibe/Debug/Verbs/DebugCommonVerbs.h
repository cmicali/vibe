//
//  DebugCommonVerbs.h
//  Vibe
//
//  The verbs both platforms answer identically, written once against
//  VibeDebugPlayerSurface. A verb lands here only when the surface is enough
//  to implement it; each platform's table is this one plus its own. The verbs
//  are split by topic, one file each.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

@class AudioPlayer;

NS_ASSUME_NONNULL_BEGIN

// DebugCommonVerbs.m's state and transport verbs, then each topic's below.
NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void);

// The topic tables, which only the common table reads.
NSArray<NSDictionary *> *VibeDebugStallVerbs(void);   // DebugStallVerbs.m
NSArray<NSDictionary *> *VibeDebugAudioVerbs(void);   // DebugAudioVerbs.m
NSArray<NSDictionary *> *VibeDebugLoadingVerbs(void); // DebugLoadingVerbs.m

// dump_state's "player", "currentTrack" and "playlist" blocks, shared because
// the stress oracles read these keys on both platforms. Returned mutable, with
// mutable sub-dictionaries, so each platform can add its "ui" block and macOS
// its own "player" fields.
NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface);

// The cores of `scan_bpm` and `scan_key`, in DebugBPMScan.mm (ObjC++, for the
// waveform mono mix). Each decodes the file and runs its analyzer in the
// calling process, returning one JSON object with a timing split:
// {"ok","bpm"} where bpm 0 means no confident tempo, {"ok","key","camelot",
// "index"} where empty names and index -1 mean no confident key, or {"error"}.
//
// They touch no app state, so the mac's CLI client runs these verbs locally:
// they work with no app running and never touch a running instance. The
// command-table entries run the same functions app-side, for callers that
// post the command file directly and for the iOS app. scan_key is the mac's
// alone, since key analysis is.
//
// Sandbox: the running app reads only paths it has been granted, and the
// direct-exec'd client only its container. So scan-bpm.sh and scan-key.sh
// stream the file through stdin (`scan_bpm -`) and the client stages it in
// the container tmp.
FOUNDATION_EXTERN NSString *VibeDebugBPMScanJSON(NSString *rawPath);
FOUNDATION_EXTERN NSString *VibeDebugKeyScanJSON(NSString *rawPath);

// "playing", "paused" or "stopped". Reads "playing" during an in-flight open,
// as the transport control does, since loading reports isPlaying.
NSString *VibeDebugPlayerStateName(AudioPlayer *player);

NS_ASSUME_NONNULL_END

#endif

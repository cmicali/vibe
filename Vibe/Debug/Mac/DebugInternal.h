//
//  DebugInternal.h
//  Vibe
//
//  Shared by the mac channel's translation units: the imports they all need
//  and the functions that cross between them. Everything else stays static.
//

#if DEBUG

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>

#import "DebugUtil.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugCommonVerbs.h"
#import "DebugConsistency.h"
#import "DebugHealth.h"
#import "DebugSettingsUI.h"
#import "AudioLoadTiming.h"

#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Debug.h"
#import "MainPlayerController+DebugPlayerSurface.h"
#import "MainPlayerController+Transport.h"
#import "MainPlayerController+Window.h"
#import "TrackDisplayController.h"
#import "MainWindow.h"
#import "MainPlayerContentView.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "AudioFileConverter+Debug.h"
#import "MusicalKey.h"
#import "PlaylistController.h"
#import "PlaylistDropZoneView.h"
#import "PitchControlPanel.h"
#import "SymbolButton.h"
#import "AppSettings.h"
#import "NSURLUtil.h"

NS_ASSUME_NONNULL_BEGIN

// DebugScreenshot.m — window capture.
BOOL VibeDumpWindowSnapshot(NSString *path);

// DebugStateDump.m — what the inspection verbs read.
NSDictionary *VibeStateDictionary(MainPlayerController *controller);
NSString *VibeViewTreeDump(void);
NSArray *VibeMenuArray(NSMenu *menu);
NSString *VibeClickMenuItem(MainPlayerController *controller, NSString *name);
NSDictionary *VibeActionSummaryDictionary(MainPlayerController *controller);

// DebugInput.m — synthesized input, synthetic drags and row selection.
NSString *VibeInjectKey(MainPlayerController *controller, NSArray<NSString *> *tokens,
                        BOOL down, BOOL up);
NSString *VibeSetShortcut(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeResetShortcuts(MainPlayerController *controller);
NSString *VibeInjectMouse(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeTestGesture(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeSelectPlaylistRows(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeSyntheticFileDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeSyntheticFileDragEnd(MainPlayerController *controller);
NSString *VibeSyntheticFileDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeReorderBegin(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeReorderUpdate(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeReorderDrop(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeReorderCancel(MainPlayerController *controller);

// DebugCommandTable.m — the verb table the dispatcher walks.
NSArray<NSDictionary *> *VibeDebugCommandTable(void);

NS_ASSUME_NONNULL_END

#endif

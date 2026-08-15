//
//  DebugInternal.h
//  Vibe
//
//  Shared by the debug channel's translation units: the imports they all need,
//  and the functions that cross between them. Everything else in those files
//  stays static. Debug builds only — the whole channel compiles out of Release.
//

#if DEBUG

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <MediaPlayer/MediaPlayer.h>
#import <notify.h>

#import "DebugUtil.h"
#import "DebugShared.h"
#import "DebugHealth.h"
#import "DebugSettingsUI.h"
#import "AudioLoadTiming.h"

#import "AppDelegate.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Debug.h"
#import "MainPlayerController+Transport.h"
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
#import "MusicalKey.h"
#import "PlaylistController.h"
#import "PlaylistDropZoneView.h"
#import "PitchControlPanel.h"
#import "SymbolButton.h"
#import "NSURLUtil.h"
#import "AppStats.h"

// One handler per verb, where tokens[0] is the verb itself. Returning nil
// means the command completes asynchronously and writes its own response later
// through VibeWriteDebugResponse(commandId, ...), from a completion block.
typedef NSString * _Nullable (^VibeDebugCommandHandler)(NSArray<NSString *> *tokens,
                                                        NSString *commandId,
                                                        MainPlayerController *controller);

// DebugScreenshot.m — window capture.
BOOL VibeDumpWindowSnapshot(NSString *path);

// DebugStateDump.m — what the inspection verbs read.
NSDictionary *VibeStateDictionary(MainPlayerController *controller);
NSString *VibeViewTreeDump(void);
NSArray *VibeMenuArray(NSMenu *menu);
NSString *VibeClickMenuItem(NSString *name);
NSString *VibeActionSummary(MainPlayerController *controller);

// DebugInput.m — synthesized keyboard, mouse and file drags.
NSString *VibeInjectKey(MainPlayerController *controller, NSArray<NSString *> *tokens,
                        BOOL down, BOOL up);
NSString *VibeInjectMouse(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeSyntheticDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens);
NSString *VibeSyntheticDragEnd(MainPlayerController *controller);
NSString *VibeSyntheticDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens);

// DebugUtil.m — argument helpers shared with the command table, and the reply.
NSString *VibeRestArgument(NSArray<NSString *> *tokens);
NSString *VibePathArgument(NSArray<NSString *> *tokens);
NSString *VibeExistingFileArgument(NSArray<NSString *> *tokens, NSString **errorJSON);
void VibeWriteDebugResponse(NSString *commandId, NSString *response);

// DebugCommandTable.m — the verb table the dispatcher walks.
NSArray<NSDictionary *> *VibeDebugCommandTable(void);

#endif

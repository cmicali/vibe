//
//  PlayerViewController.h
//  Vibe (iOS)
//
//  The player screen: the iOS counterpart of MainPlayerController. Owns the
//  engine, the playlist, both caches, the Now Playing bridge, the audio
//  session, and the folder session; the UI is the SoundCloud-style waveform
//  scrubber with playlist, play/pause, and next.
//

#import <UIKit/UIKit.h>

@interface PlayerViewController : UIViewController

// "Open in Vibe" from Files or the share sheet, forwarded by the scene
// delegate.
- (void)handleOpenURLContexts:(NSSet<UIOpenURLContext *> *)contexts;

@end

#if DEBUG

@class AudioTrackMetadataCache;
@class AudioWaveformCache;

// Extra surface for the debug command channel (DebugCommands.m), the iOS twin
// of MainPlayerController+Debug.h. Implemented at the bottom of the class's
// own .m for ivar access. Debug builds only.
@interface PlayerViewController (Debug)

- (NSDictionary *)debugStateDictionary;
// The compact reply the transport verbs share.
- (NSDictionary *)debugActionSummary;
- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPrevious;
// Routes through the scrubber's didSeek path so the seek-in-flight guard
// behaves exactly as a real drag's release.
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;
- (void)debugOpenPath:(NSString *)path;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif

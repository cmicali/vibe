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

// Restores the persisted folder session, or shows the empty state. The scene
// delegate calls exactly one of this and handleOpenURLContexts: at launch —
// a cold "Open in Vibe" must not pay for (and then discard) a full restore.
- (void)restorePersistedSession;

@end


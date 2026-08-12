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

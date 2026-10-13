//
//  MainPlayerController+Delivery.h
//  Vibe
//
//  Where async results land: metadata, waveform, detected BPM and key. Also
//  the grant, folder-art and thumbnail notifications. **A delivery can arrive
//  after the track changed**, so each receiver matches the delivered URL or
//  track against its target. BPM and key stamp every row with the analyzed
//  sourceKey. CUE windows sharing a URL remain distinct. The label refreshes
//  only when a matching row is current.
//

#import "MainPlayerController.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Delivery) <AudioTrackMetadataCacheDelegate,
                                            AudioWaveformCacheDelegate>

// Observed from windowDidLoad.
- (void)grantedFoldersDidChange:(NSNotification *)notification;
- (void)thumbnailDidLoad:(NSNotification *)notification;
- (void)folderArtDidResolve:(NSNotification *)notification;

@end

NS_ASSUME_NONNULL_END

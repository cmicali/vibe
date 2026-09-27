//
//  MainPlayerController+Delivery.h
//  Vibe
//
//  Where async results land — metadata, waveform, detected BPM and key — plus
//  the waveform view's scrub seek. **A delivery can arrive after the track
//  changed**, so each receiver matches the delivered URL or track against the
//  current one. One file can fill several rows, so BPM and key stamp every row
//  owning the URL and refresh the label only if one is on display.
//

#import "MainPlayerController.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Delivery) <AudioTrackMetadataCacheDelegate,
                                            AudioWaveformCacheDelegate,
                                            AudioWaveformViewDelegate>
@end

NS_ASSUME_NONNULL_END

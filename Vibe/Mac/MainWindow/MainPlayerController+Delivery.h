//
//  MainPlayerController+Delivery.h
//  Vibe
//
//  Where the asynchronous results land: parsed metadata, waveform snapshots,
//  and the BPM and key an analysis pass detected. Plus the one input that
//  arrives on the same surface, the waveform view's scrub seek.
//
//  All four deliveries implement one cross-directory guarantee, which is why
//  they are one file: **an async delivery can arrive after the track has
//  changed**, so a receiver matches the delivered URL or track against the
//  current one before applying it. The BPM and key deliveries carry a second
//  rule on top — the same file can occupy more than one playlist row, so they
//  stamp *every* row owning that URL and refresh the label only if one of them
//  is the one on display.
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

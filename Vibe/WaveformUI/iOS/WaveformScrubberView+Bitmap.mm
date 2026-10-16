//
//  WaveformScrubberView+Bitmap.mm
//  Vibe (iOS)
//
//  The one picture: the bake, its store, its segments, the install and the
//  reveal of a streaming load's newest stretch.
//

#import "WaveformScrubberViewInternal.h"
#import "WaveformRendererRegistry.h"
#import "WaveformZoomMath.h"
#import "UIView+DarkMode.h"

// How often a streaming load re-bakes: it delivers ~10 times a second, and a
// swap per delivery reads as flicker. Trailing, so the newest shape wins, and
// steady, so the picture fills in at one pace whatever the decode's.
static const NSTimeInterval kLoadBakeMinInterval = 0.4;

// How long a partial waveform waits for its load to complete before it shows.
// Most loads complete inside it and enter once, at their final heights; only
// a slow one shows partials and then the completion's grow.
static const NSTimeInterval kFirstPartialDelay = 0.5;

// A bitmap's entrance. The first onto an empty view grows from the midline;
// a complete one over a partial one grows from the partial's heights to its
// own, since Normalize raises the reference only for the whole track and the
// bars would jump taller. Every other install is an instant swap.
static const CFTimeInterval kArrivalGrowDuration = 0.3;
// A streaming load's newly decoded stretch grows up from the midline; the
// rest of the picture holds still. Under kLoadBakeMinInterval, so one reveal
// ends before the next swap. A steep ease in and out, so it reads as a snap
// rather than a drift.
static const CFTimeInterval kChunkGrowDuration = 0.2;
static const CFTimeInterval kCompletionGrowDuration = 0.35;

// Every complete bake, keyed by what it shows, so a page arriving with its
// pixels already baked — by a hidden neighbor baker or by its own earlier
// cell — installs them on the turn it appears. Main thread only. Each entry
// holds its waveform, so the address its key names cannot be reused by
// another while the entry lives. The width is left out of the key: a bake of
// another zoom installs stretched, as a pinch frame shows, and re-bakes once.
static NSCache<NSString *, NSArray *> *VibeBakeStore(void) {
    static NSCache *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[NSCache alloc] init];
        store.countLimit = 3;
        // An entry is a played and an unplayed bitmap, each up to the budget.
        store.totalCostLimit = (NSUInteger)(3 * 2 * kVibeMaxBakeImageBytes);
    });
    return store;
}

@implementation WaveformScrubberView (Bitmap)

- (void)prepareForWaveformLoad {
    _playbackLoading = NO;
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    [self installRendererIfNeeded];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [self showWaveform:waveform animated:YES];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated {
    // A page brought back by a swipe is handed what it already shows.
    if ([self isShowingCompleteWaveform:waveform]) {
        return;
    }
    // Per-page cells can hydrate without prepareForWaveformLoad.
    [self installRendererIfNeeded];
    CGSize size = [self virtualBounds].size;
    NSArray *stored = [VibeBakeStore() objectForKey:[self bakeKeyForWaveform:waveform
            height:size.height scale:[self displayScale] dark:self.isDark
            style:_styleIdentifier signature:_themeSignature]];
    if (stored) {
        self.waveform = waveform;
        _animatesArrival = animated;
        [self invalidatePendingBake];
        [self installEnvelopeImage:(__bridge CGImageRef)stored[0]
                    unplayedImage:stored[1] == NSNull.null ? nil : (__bridge CGImageRef)stored[1]
                            epoch:_bakeEpoch complete:YES normalizationGain:1 decodedFraction:1];
        if ([stored[3] doubleValue] != size.width) {
            [self scheduleEnvelopeBakeAfter:0];
        }
        return;
    }
    // Snapshots are immutable, so a complete one already held has its bake
    // pending, and the view re-bakes itself on any change: asking again would
    // queue a duplicate behind a bake in flight.
    if (waveform == self.waveform && waveform.waveform->isComplete()) {
        return;
    }
    VibeSignpostBegin(waveform_delivery);
    self.waveform = waveform;
    _animatesArrival = animated;
    CFTimeInterval now = CACurrentMediaTime();
    if (_firstDeliveryAt == 0) {
        _firstDeliveryAt = now;
    }
    // The complete one as soon as it can be drawn; a first partial once its
    // load has had kFirstPartialDelay to complete; later partials at a steady
    // pace.
    NSTimeInterval delay = 0;
    if (!waveform.waveform->isComplete()) {
        delay = _bakedHost ? [self throttledBakeDelay]
                           : MAX(0, _firstDeliveryAt + kFirstPartialDelay - now);
    }
    [self scheduleEnvelopeBakeAfter:delay];
    VibeSignpostEnd(waveform_delivery);
}

// Every input of a bake but its width (the zoom), the shape themeSignature
// uses.
- (NSString *)bakeKeyForWaveform:(CodableAudioWaveform *)waveform height:(CGFloat)height
                           scale:(CGFloat)scale dark:(BOOL)dark style:(NSString *)style
                       signature:(NSString *)signature {
    return [NSString stringWithFormat:@"%p|%g|%g|%d|%@|%@", waveform, height, scale, dark, style,
            signature];
}

// 0, or the rest of the window, so a burst collapses to one bake.
- (NSTimeInterval)throttledBakeDelay {
    CFTimeInterval since = CACurrentMediaTime() - _lastBakeAt;
    if (since >= kLoadBakeMinInterval) {
        return 0;
    }
    return kLoadBakeMinInterval - since;
}

#pragma mark - The bitmap

// TRAP: the picture is only ever this bitmap; never show the renderer's
// live tree. It is a multi-screen layer under a mask of thousands of rects,
// which the render server scan-converts on the CPU each frame it moves.
// Scrolling a bitmap avoids that work.

// A bake scheduled or in flight can no longer install.
- (void)invalidatePendingBake {
    _bakeEpoch++;
    _bakeRequest++;
    _bakeWanted = NO;
}

- (void)removeBakedWaveform {
    [self invalidatePendingBake];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_bakedHost removeFromSuperlayer];
    _bakedHost = nil;
    _bakedPlayedImage = nil;
    _bakedUnplayedImage = nil;
    _revealLayer = nil;
    _bakedDecodedFraction = 0;
    [CATransaction commit];
}

- (void)scheduleEnvelopeBakeAfter:(NSTimeInterval)delay {
    _bakeRequest++;
    if (!self.waveform || !_renderer) {
        return;
    }
    NSUInteger request = _bakeRequest;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf bakeEnvelopeForRequest:request];
    });
}

// A finished bake installs while the epoch holds, even if a newer delivery
// arrived. A request mid-bake waits. This avoids discarding expensive pixel
// work for each streaming delivery.
- (void)bakeEnvelopeForRequest:(NSUInteger)request {
    if (request != _bakeRequest || !self.waveform) {
        return;
    }
    if (_bakeInFlight) {
        _bakeWanted = YES;
        return;
    }
    CGSize size = [self virtualBounds].size;
    if (size.width <= 0 || size.height <= 0) {
        return;
    }
    _lastBakeAt = CACurrentMediaTime();
    WaveformRenderer *renderer = _renderer;
    CGFloat scale = [self displayScale];
    // Past the texture ceiling a layer renders BLANK: a layout wide enough that
    // even the resting zoom overflows (the zoom floor keeps a pinch out) bakes
    // at reduced scale and stretches back.
    if (size.width * scale > kVibeMaxBakeImagePixels) {
        scale = MAX(kVibeMaxBakeImagePixels / size.width, 0.25);
    }
    CodableAudioWaveform *waveform = self.waveform;
    BOOL complete = waveform.waveform->isComplete();
    CGFloat normalizationGain = complete ? [renderer normalizationGainForWaveform:waveform.waveform] : 1;
    CGFloat decodedFraction = waveform.waveform->decodedFraction();
    // Drawn whole through the registry, as the widget draws it: once all
    // played, once all unplayed.
    NSString *style = _styleIdentifier;
    WaveformTheme *theme = _bakeTheme;
    BOOL dark = self.isDark;
    BOOL centered = renderer.centered;
    NSString *storeKey = complete ? [self bakeKeyForWaveform:waveform height:size.height
            scale:[self displayScale] dark:dark style:style signature:_themeSignature] : nil;
    NSUInteger epoch = _bakeEpoch;
    _bakeInFlight = YES;
    _bakeWanted = NO;
    __weak WaveformScrubberView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VibeSignpostBegin(waveform_bake);
        CGImageRef image = [WaveformRendererRegistry newImageForCodableWaveform:waveform identifier:style
                pointSize:size scale:scale progress:1 dark:dark theme:theme
                barDensity:1 barWidth:1 centered:centered normalize:YES gainDB:0];
        CGImageRef unplayedImage = [WaveformRendererRegistry newImageForCodableWaveform:waveform identifier:style
                pointSize:size scale:scale progress:0 dark:dark theme:theme
                barDensity:1 barWidth:1 centered:centered normalize:YES gainDB:0];
        VibeSignpostEnd(waveform_bake);
        dispatch_async(dispatch_get_main_queue(), ^{
            WaveformScrubberView *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_bakeInFlight = NO;
                [strongSelf installEnvelopeImage:image unplayedImage:unplayedImage epoch:epoch
                                        complete:complete normalizationGain:normalizationGain
                                 decodedFraction:decodedFraction];
                if (storeKey && image && strongSelf->_bakedPlayedImage == (__bridge id)image) {
                    size_t cost = CGImageGetBytesPerRow(image) * CGImageGetHeight(image);
                    if (unplayedImage) {
                        cost += CGImageGetBytesPerRow(unplayedImage) * CGImageGetHeight(unplayedImage);
                    }
                    [VibeBakeStore() setObject:@[(__bridge id)image,
                                                 (__bridge id)unplayedImage ?: NSNull.null, waveform,
                                                 @(size.width)]
                                        forKey:storeKey cost:cost];
                }
                if (strongSelf->_bakeWanted) {
                    strongSelf->_bakeWanted = NO;
                    [strongSelf scheduleEnvelopeBakeAfter:[strongSelf throttledBakeDelay]];
                }
            }
            CGImageRelease(image);
            CGImageRelease(unplayedImage);
            // Captured so a renderer outliving its view is released here, on
            // main: its dealloc tears down layers.
            (void)renderer;
        });
    });
}

// At the CURRENT geometry: a bitmap drawn for an older one is stretched to it
// (resize gravity) until the re-bake the change asked for lands, so a resize,
// a rotation or a pinch never blanks the strip.
- (void)placeBakedLayer:(CALayer *)host {
    CGFloat oldWidth = host.bounds.size.width;
    CGRect bounds = [self virtualBounds];
    host.bounds = bounds;
    host.position = CGPointMake(0, bounds.size.height / 2);
    for (CALayer *segment in host.sublayers) {
        CGFloat start = oldWidth > 0 ? segment.position.x / oldWidth : 0;
        CGFloat length = oldWidth > 0 ? segment.bounds.size.width / oldWidth : 1;
        segment.bounds = CGRectMake(0, 0, length * bounds.size.width, bounds.size.height);
        segment.position = CGPointMake(start * bounds.size.width, bounds.size.height / 2);
        segment.sublayers.firstObject.frame = segment.bounds;
    }
}

// [start, end) of the track, in the standing images. Anchored at the midline,
// so a reveal grows it from there.
- (CALayer *)newSegmentFrom:(CGFloat)start to:(CGFloat)end {
    return [self newSegmentFrom:start to:end played:_bakedPlayedImage
                       unplayed:_bakedUnplayedImage unplayedOpacity:_bakedUnplayedOpacity];
}

- (CALayer *)newSegmentFrom:(CGFloat)start to:(CGFloat)end played:(id)playedImage
                   unplayed:(id)unplayedImage unplayedOpacity:(float)unplayedOpacity {
    CGRect bounds = _bakedHost.bounds;
    CALayer *segment = [CALayer layer];
    segment.anchorPoint = CGPointMake(0, 0.5);
    segment.bounds = CGRectMake(0, 0, (end - start) * bounds.size.width, bounds.size.height);
    segment.position = CGPointMake(start * bounds.size.width, bounds.size.height / 2);
    CALayer *unplayed = [CALayer layer];
    unplayed.frame = segment.bounds;
    unplayed.contents = unplayedImage;
    unplayed.opacity = unplayedOpacity;
    unplayed.contentsRect = CGRectMake(start, 0, end - start, 1);
    [segment addSublayer:unplayed];
    CALayer *played = [CALayer layer];
    played.actions = @{@"bounds": NSNull.null, @"position": NSNull.null,
                       @"contentsRect": NSNull.null};
    played.anchorPoint = CGPointZero;
    played.position = CGPointZero;
    played.contents = playedImage;
    [segment addSublayer:played];
    [_bakedHost addSublayer:segment];
    return segment;
}
- (void)installEnvelopeImage:(CGImageRef)image unplayedImage:(nullable CGImageRef)unplayedImage
                       epoch:(NSUInteger)epoch complete:(BOOL)complete
           normalizationGain:(CGFloat)normalizationGain
             decodedFraction:(CGFloat)decodedFraction {
    if (!image || epoch != _bakeEpoch || !self.waveform) {
        return;
    }
    VibeSignpostBegin(waveform_install);
    BOOL arrival = !_bakedHost;
    CGFloat revealFrom = _bakedDecodedFraction;
    _revealLayer = nil;
    BOOL completes = _bakedHost && !_bakedComplete && complete;
    BOOL reveals = !arrival && !_isPinching && decodedFraction > revealFrom;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // TRAP: drop the standing bitmap first, or it stays in the scroll's tree
    // for the life of the view. Never fade one picture over another: the
    // waveforms are translucent, so the pair drew brighter than either for the
    // fade and the end of it dimmed in one frame.
    [_bakedHost removeFromSuperlayer];
    // The undecoded tail of a reveal is cut from the picture being replaced.
    id previousPlayed = _bakedPlayedImage;
    id previousUnplayed = _bakedUnplayedImage;
    float previousOpacity = _bakedUnplayedOpacity;
    _bakedPlayedImage = (__bridge id)image;
    _bakedUnplayedImage = (__bridge id)(unplayedImage ?: image);
    // The unplayed side's own bake is already at its resting alphas.
    _bakedUnplayedOpacity = 1;
    // No geometryFlipped here: the bake draws in CG's y-up space, whose top
    // row lands at the layer's top.
    _bakedHost = [CALayer layer];
    _bakedHost.anchorPoint = CGPointMake(0, 0.5);
    [self placeBakedLayer:_bakedHost];
    if (reveals) {
        [self revealDecodedFrom:revealFrom to:decodedFraction tailPlayed:previousPlayed
                   tailUnplayed:previousUnplayed tailUnplayedOpacity:previousOpacity];
    }
    else {
        [self newSegmentFrom:0 to:1];
    }
    [_scroll.layer insertSublayer:_bakedHost above:_rendererHost];
    // TRAP: crop the played side inside this transaction. Called from a block
    // on main, it is top-level and commits at once, and a played layer left at
    // zero width for that frame drew the whole track unplayed: on a slow load
    // the played side blinked at every swap.
    [self applyPlayedClip];
    _bakedComplete = complete;
    if (arrival) {
        // The picture ends the shimmer, not the data: until it lands the
        // strip would be empty. The fill stays; see hideLoadingShimmer.
        [self hideLoadingShimmer];
    }
    if (arrival && _animatesArrival) {
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        grow.fromValue = @0;
        grow.toValue = @1;
        grow.duration = kArrivalGrowDuration;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_bakedHost addAnimation:grow forKey:@"arrival"];
    }
    else if (completes && normalizationGain > 1.001) {
        // Over the last stretch's own reveal, which it carries up with it.
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        grow.fromValue = @(1 / normalizationGain);
        grow.toValue = @1;
        grow.duration = kCompletionGrowDuration;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_bakedHost addAnimation:grow forKey:@"completionGrow"];
    }
    _bakedDecodedFraction = decodedFraction;
    [CATransaction commit];
    [self applyScrollAndProgress];
    VibeSignpostEnd(waveform_install);
}
// Inside the install's transaction: the picture as three segments for the
// reveal's length — before the new stretch, the stretch growing up from the
// midline, and the undecoded rest — then one again. No mask, so no offscreen
// pass, and each segment crops its own played side, so the stretch grows the
// same on either side of the playhead.
//
// TRAP: every stretch outside the new one must stay drawn. Cropping one layer
// at the old edge hid the undecoded midline for each reveal, and it blinked at
// every swap; growing only the unplayed side popped a stretch the playhead had
// passed.
- (void)revealDecodedFrom:(CGFloat)from to:(CGFloat)to tailPlayed:(id)tailPlayed
                tailUnplayed:(id)tailUnplayed tailUnplayedOpacity:(float)tailUnplayedOpacity {
    if (from > 0) {
        [self newSegmentFrom:0 to:from];
    }
    // TRAP: everything past the old edge comes from the PREVIOUS picture,
    // where it is all midline. A drawn bar is wider than a chunk and straddles
    // the decoded edge, so in the new picture the edge bar's sliver lies past
    // it: cut from there, it stood at full height while the stretch grew.
    // Padding the stretch past its edges instead regrew bars already shown,
    // and the stretch no longer fit where it belonged.
    if (to < 1) {
        [self newSegmentFrom:to to:1 played:tailPlayed unplayed:tailUnplayed
             unplayedOpacity:tailUnplayedOpacity];
    }
    // TRAP: under the stretch, the previous picture only while the stretch is
    // near a hairline, which smooth outlines (3-Band) do not draw at all, so
    // the midline had a gap there. Left for the whole grow, its bright midline
    // and the cliff at its old edge showed through the translucent stretch.
    CALayer *underlay = [self newSegmentFrom:from to:to played:tailPlayed unplayed:tailUnplayed
                             unplayedOpacity:tailUnplayedOpacity];
    underlay.opacity = 0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.duration = kChunkGrowDuration / 2;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [underlay addAnimation:fade forKey:@"underlayFade"];
    CALayer *reveal = [self newSegmentFrom:from to:to];
    _revealLayer = reveal;
    // Set before the animations, which it then waits for: the last stretch's
    // and, at completion, the whole picture's.
    __weak WaveformScrubberView *weakSelf = self;
    [CATransaction setCompletionBlock:^{
        [weakSelf finishRevealOf:reveal];
    }];
    // From a hairline, not from nothing: at zero the stretch left a gap in
    // the midline it grows out of.
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
    grow.fromValue = @(MIN(1.0, 1 / MAX(1.0, _bakedHost.bounds.size.height * [self displayScale])));
    grow.toValue = @1;
    grow.duration = kChunkGrowDuration;
    grow.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.7f :0.0f :0.3f :1.0f];
    [reveal addAnimation:grow forKey:@"chunkGrow"];
}
// A stale reveal is a no-op: a newer install or a reset replaced it.
- (void)finishRevealOf:(CALayer *)reveal {
    if (!reveal || reveal != _revealLayer) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _revealLayer = nil;
    for (CALayer *segment in [_bakedHost.sublayers copy]) {
        [segment removeFromSuperlayer];
    }
    [self newSegmentFrom:0 to:1];
    [self applyPlayedClip];
    [CATransaction commit];
}

@end

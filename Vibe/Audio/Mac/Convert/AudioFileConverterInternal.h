//
//  AudioFileConverterInternal.h
//  Vibe
//
//  The private surface shared between AudioFileConverter.m and its sandbox
//  category: the related-item presenter class, and the class extension holding
//  the two ivars the placement rungs reach. Do not use it outside the
//  converter's implementation files; everything else goes through
//  AudioFileConverter.h.
//

#import "AudioFileConverter.h"

NS_ASSUME_NONNULL_BEGIN

// Announces the FLAC as a related item of the source. Registering it makes
// the sandbox extend a single-file grant to the sibling name, and requires
// the flac extension declared as a related-item type in Info.plist; see
// project.yml.
@interface VibeRelatedItemPresenter : NSObject <NSFilePresenter>
- (instancetype)initWithPresentedURL:(NSURL *)presentedURL primaryURL:(NSURL *)primaryURL;
@end

@interface AudioFileConverter () {
    // The converter's own serial queue. Every file move runs on it, because a
    // destination on another volume turns a move into a full copy and an
    // unreachable mount blocks until it times out.
    dispatch_queue_t _queue;
    // Presenters for FLACs only the related-item path could write, kept
    // registered for the session: the sandbox extension dies with the
    // registration, leaving a just-written file unreadable. Mutated only on
    // the converter queue; created in init before publication, and dealloc's
    // teardown iteration never races the queue because the app-lifetime
    // instance is never released.
    NSMutableArray<VibeRelatedItemPresenter *> *_relatedItemPresenters;
}
@end

NS_ASSUME_NONNULL_END

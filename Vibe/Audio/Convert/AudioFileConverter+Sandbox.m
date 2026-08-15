//
//  AudioFileConverter+Sandbox.m
//  Vibe
//

#import "AudioFileConverter+Sandbox.h"
#import "AudioFileConverterInternal.h"
#import "VibeStrings.h"

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Declared in AudioFileConverterInternal.h, because AudioFileConverter.m's
// dealloc unregisters the array this type fills. Rung 2 below is the only
// place one is ever built.
@implementation VibeRelatedItemPresenter {
    NSURL *_presentedURL;
    NSURL *_primaryURL;
    NSOperationQueue *_queue;
}

- (instancetype)initWithPresentedURL:(NSURL *)presentedURL primaryURL:(NSURL *)primaryURL {
    self = [super init];
    if (self) {
        _presentedURL = presentedURL;
        _primaryURL = primaryURL;
        _queue = [NSOperationQueue new];
        _queue.maxConcurrentOperationCount = 1;
    }
    return self;
}

- (NSURL *)presentedItemURL { return _presentedURL; }
- (NSURL *)primaryPresentedItemURL { return _primaryURL; }
- (NSOperationQueue *)presentedItemOperationQueue { return _queue; }

@end

@implementation AudioFileConverter (Sandbox)

- (nullable NSURL *)moveTemp:(NSURL *)tempURL
                      source:(NSURL *)sourceURL
                 destination:(NSURL *)destinationURL
                       error:(NSError **)error {
    NSError *moveError = nil;
    if ([NSFileManager.defaultManager moveItemAtURL:tempURL toURL:destinationURL error:&moveError]) {
        return destinationURL;
    }
    LogInfo(@"Direct write to %@ failed (%@); trying the related-item path",
            destinationURL.lastPathComponent, moveError.localizedDescription);
    if (error) {
        *error = moveError;
    }
    return [self moveTemp:tempURL toRelatedItem:destinationURL ofPrimary:sourceURL];
}

// Rung 2; see the header. A successful presenter is kept, because the sandbox
// extension dies with the registration.
- (nullable NSURL *)moveTemp:(NSURL *)tempURL
               toRelatedItem:(NSURL *)destinationURL
                   ofPrimary:(NSURL *)primaryURL {
    VibeRelatedItemPresenter *presenter =
            [[VibeRelatedItemPresenter alloc] initWithPresentedURL:destinationURL primaryURL:primaryURL];
    [NSFileCoordinator addFilePresenter:presenter];

    __block NSURL *writtenURL = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:presenter];
    NSError *coordinationError = nil;
    [coordinator coordinateWritingItemAtURL:destinationURL
                                    options:NSFileCoordinatorWritingForReplacing
                                      error:&coordinationError
                                 byAccessor:^(NSURL *writeURL) {
        // A handed URL other than the sibling path is a tracked older item —
        // a previously trashed foo.flac — and following it would file the new
        // FLAC in the Trash.
        NSURL *target = [writeURL.URLByStandardizingPath isEqual:destinationURL.URLByStandardizingPath]
                ? writeURL : destinationURL;
        NSError *moveError = nil;
        if ([NSFileManager.defaultManager moveItemAtURL:tempURL toURL:target error:&moveError]) {
            writtenURL = target;
        }
        else {
            LogInfo(@"Related-item move failed: %@", moveError.localizedDescription);
        }
    }];
    if (coordinationError) {
        LogInfo(@"Related-item coordination failed: %@", coordinationError.localizedDescription);
    }

    if (writtenURL) {
        [_relatedItemPresenters addObject:presenter];
    }
    else {
        [NSFileCoordinator removeFilePresenter:presenter];
    }
    return writtenURL;
}

- (void)runSavePanelForTemp:(NSURL *)tempURL
                destination:(NSURL *)destinationURL
                     window:(NSWindow *)window
                 completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = STR_MENU_CONVERT_TO_FLAC;
    panel.message = STR_LABEL_CONVERT_SAVE_MESSAGE;
    panel.directoryURL = destinationURL.URLByDeletingLastPathComponent;
    panel.nameFieldStringValue = destinationURL.lastPathComponent;
    // FLAC has no UTType constant of its own; org.xiph.flac is the identifier
    // the app already declares in CFBundleDocumentTypes.
    UTType *flacType = [UTType typeWithIdentifier:@"org.xiph.flac"];
    panel.allowedContentTypes = flacType ? @[flacType] : @[];

    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        NSURL *chosenURL = panel.URL;
        if (response != NSModalResponseOK || !chosenURL) {
            completion(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                                code:NSUserCancelledError
                                            userInfo:nil]);
            return;
        }
        // Off main like the silent rungs: a destination on another volume
        // turns the move into a full copy of the encoded file, and an
        // unreachable mount blocks until it times out.
        dispatch_async(self->_queue, ^{
            NSFileManager *fileManager = NSFileManager.defaultManager;
            NSError *moveError = nil;
            NSURL *placedURL = nil;
            if ([fileManager fileExistsAtPath:chosenURL.path]) {
                // The panel already asked about replacing. The replace must be
                // atomic: delete-then-move would destroy the existing file
                // even when the move then fails.
                NSURL *resultingURL = nil;
                if ([fileManager replaceItemAtURL:chosenURL
                                    withItemAtURL:tempURL
                                   backupItemName:nil
                                          options:0
                                 resultingItemURL:&resultingURL
                                            error:&moveError]) {
                    placedURL = resultingURL ?: chosenURL;
                }
            }
            else if ([fileManager moveItemAtURL:tempURL toURL:chosenURL error:&moveError]) {
                placedURL = chosenURL;
            }
            run_on_main_thread({ completion(placedURL, placedURL ? nil : moveError); });
        });
    }];
}

@end

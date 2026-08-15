//
//  FolderArtEntry.m
//  Vibe
//

#import "FolderArtEntry.h"

@implementation VibeFolderArtEntry

- (BOOL)settled {
    return _artPath != nil;
}

- (BOOL)settledEmpty {
    return _artPath != nil && _artPath.length == 0;
}

- (BOOL)busy {
    return _resolving != 0 || _decoding > 0 || _scheduled;
}

- (void)forgetSettledAnswer {
    _artPath = nil;
    _revision = 0;
    _resolving = 0;
    _settledWithoutGrant = NO;
    _readFailures = 0;
}

@end

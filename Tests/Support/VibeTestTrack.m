//
//  VibeTestTrack.m
//

#import "VibeTestTrack.h"

#import "NSURL+Hash.h"

@implementation VibeTestTrack {
    NSString *_sourceKey;
}

@synthesize url = _url, cueStart = _cueStart, cueEnd = _cueEnd;

+ (VibeTestTrack *)withURL:(NSURL *)url {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd {
    if ((self = [super init])) {
        _url = [url copy];
        _cueStart = cueStart;
        _cueEnd = cueEnd;
        _sourceKey = VibeKeyByAppendingCueWindow(url.path, cueStart, cueEnd) ?: @"";
    }
    return self;
}

- (NSString *)sourceKey {
    return _sourceKey;
}

- (NSString *)cacheKey {
    return self.url.cacheKey;
}

@end

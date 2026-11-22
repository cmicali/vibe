//
//  VibeTrackRow.m
//  Vibe (iOS)
//

#import "VibeTrackRow.h"

@implementation VibeTrackRow

static BOOL SameText(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

- (id)copyWithZone:(NSZone *)zone {
    VibeTrackRow *copy = [[VibeTrackRow alloc] init];
    copy.title = _title;
    copy.subtitle = _subtitle;
    copy.thumbnail = _thumbnail;
    copy.durationText = _durationText;
    copy.numberText = _numberText;
    copy.playing = _playing;
    return copy;
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:VibeTrackRow.class]) {
        return NO;
    }
    VibeTrackRow *row = object;
    return row.thumbnail == _thumbnail && row.playing == _playing
            && SameText(row.title, _title) && SameText(row.subtitle, _subtitle)
            && SameText(row.durationText, _durationText) && SameText(row.numberText, _numberText);
}

- (NSUInteger)hash {
    return _title.hash ^ _numberText.hash;
}

@end

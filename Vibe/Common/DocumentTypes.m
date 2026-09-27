//
//  DocumentTypes.m
//  Vibe
//

#import "DocumentTypes.h"

@implementation DocumentTypes

+ (NSArray<UTType *> *)declaredTypes {
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    NSArray *documentTypes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
    for (NSDictionary *documentType in documentTypes) {
        // A related-item declaration is sandbox plumbing (Convert to FLAC's
        // sibling write); it would double-list a type in the ⌘O filter and
        // the default-player claim.
        if ([documentType[@"NSIsRelatedItemType"] boolValue]) {
            continue;
        }
        for (NSString *identifier in documentType[@"LSItemContentTypes"]) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) {
                [types addObject:type];
            }
        }
    }
    return types;
}

+ (NSArray<UTType *> *)declaredFileTypes {
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    for (UTType *type in self.declaredTypes) {
        if (![type conformsToType:UTTypeDirectory]) {
            [types addObject:type];
        }
    }
    return types;
}

@end

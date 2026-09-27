//
//  DocumentTypes.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

// Info.plist's CFBundleDocumentTypes read back as UTTypes, so the open panel's
// filter and what the app is registered for cannot drift apart.
@interface DocumentTypes : NSObject

// Every LSItemContentTypes entry across all declarations, folders included.
@property (class, readonly) NSArray<UTType *> *declaredTypes;

// The file types alone: the folder declaration is an Alternate handler, never
// something to become the system default for.
@property (class, readonly) NSArray<UTType *> *declaredFileTypes;

@end

NS_ASSUME_NONNULL_END

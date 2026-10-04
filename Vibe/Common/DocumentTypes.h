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

// The file types alone, without the folder declaration.
@property (class, readonly) NSArray<UTType *> *declaredFileTypes;

// The Default-rank declarations, in Info.plist order: what the app asks to be
// the system default for. The Alternate ones — folders and audiobooks — it
// opens without asking for.
@property (class, readonly) NSArray<UTType *> *defaultHandlerTypes;

@end

NS_ASSUME_NONNULL_END

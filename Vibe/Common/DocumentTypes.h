//
//  DocumentTypes.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

// The document types Vibe declares in Info.plist, under CFBundleDocumentTypes,
// read back as UTTypes.
//
// It is stateless, with all class methods. Info.plist is the single source of
// truth, so the open panel's filter and what the app is actually registered
// for cannot drift apart. The Launch Services side — becoming the default app
// for these types — is DefaultAppClaim (Menu/), keeping this class free of
// AppKit.
@interface DocumentTypes : NSObject

// Every LSItemContentTypes entry across all declarations, folders included.
@property (class, readonly) NSArray<UTType *> *declaredTypes;

// The file types alone. The "Folder" declaration is an Alternate handler, for
// dropping or opening a folder of tracks, and never something to become the
// system default for.
@property (class, readonly) NSArray<UTType *> *declaredFileTypes;

@end

NS_ASSUME_NONNULL_END

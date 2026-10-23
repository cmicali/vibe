//
//  LinkClient.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "HTTPTransferClient.h"
#import "LinkRules.h"

NS_ASSUME_NONNULL_BEGIN

// A link that did not open. The code is a VibeLinkError. A Server error
// carries the status under VibeHTTPErrorStatusCodeKey. The error that caused
// it, if any, is under NSUnderlyingErrorKey. Each shell shows
// VibeLinkMessageForError's string (Common/StringRules.h).
extern NSErrorDomain const VibeLinkErrorDomain;
// A link error with that code, carrying underlying and its status.
NSError *VibeLinkMakeError(VibeLinkError code, NSError *_Nullable underlying);

// The client every link goes through: the plain client, and an iCloud Drive
// share's lookup before each request to it. The lookup's address lives about
// 15 minutes, so each request gets one looked up in the last 10. A refused
// address is looked up again once. The checksum the lookup states is the
// version, so a resend after a fresh lookup continues the same bytes.
@interface LinkClient : HTTPTransferClient
@end

NS_ASSUME_NONNULL_END

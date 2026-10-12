//
//  LinkClient.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "HTTPTransferClient.h"

NS_ASSUME_NONNULL_BEGIN

// The client every link goes through: the plain client, and an iCloud Drive
// share's lookup before each request to it. The lookup's address lives about
// 15 minutes, so each request gets one looked up in the last 10. A refused
// address is looked up again once. The checksum the lookup states is the
// version, so a resend after a fresh lookup continues the same bytes.
@interface LinkClient : HTTPTransferClient
@end

NS_ASSUME_NONNULL_END

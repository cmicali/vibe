//
//  AudioFileConverter+Debug.h
//  Vibe
//
//  Debug-only fault injection at the converter's source-disposal boundary.
//

#if DEBUG

#import "AudioFileConverter.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileConverter (Debug)

// Arms one accepted conversion to report a successful source Trash without a
// resulting URL. The returned owner lets an async completion cancel only its
// own still-pending fault.
- (nullable id)debugArmOmitNextSourceTrashURL;
- (void)debugClearPendingSourceTrashURLFault;
- (void)debugCancelPendingSourceTrashURLFaultWithOwner:(id)owner;

@end

NS_ASSUME_NONNULL_END

#endif

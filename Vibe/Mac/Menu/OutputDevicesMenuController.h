//
//  OutputDevicesMenuController.h
//  Vibe
//

#import <Foundation/Foundation.h>

@class AudioPlayer;

@interface OutputDevicesMenuController : NSObject <NSMenuDelegate>

@property (weak) AudioPlayer *audioPlayer;

// The one way the shell switches output: the device with the two output modes
// AppSettings remembers for its UID, in one player call. -1 is System Output.
- (void)selectOutputDevice:(NSInteger)deviceId;

@end

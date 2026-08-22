//
//  OutputDevicesMenuController.h
//  Vibe
//

#import <Foundation/Foundation.h>

@class AudioPlayer;

@interface OutputDevicesMenuController : NSObject <NSMenuDelegate>

@property (weak) AudioPlayer *audioPlayer;

@end

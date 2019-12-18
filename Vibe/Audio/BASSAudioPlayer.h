//
//  BASSAudioPlayer.h
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@protocol BASSAudioPlayerDelegate;

@interface BASSAudioPlayer : NSObject

- (BOOL)play:(AudioTrack *)track;
- (void)loadMetadata:(NSArray<AudioTrack*>*)tracks;

@property (nullable, weak) id <BASSAudioPlayerDelegate> delegate;

@end


@protocol BASSAudioPlayerDelegate <NSObject>
@optional

- (void)audioPlayer:(BASSAudioPlayer *)audioPlayer didLoadMetadata:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END

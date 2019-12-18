//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"

#include <SFBAudioEngine/AudioMetadata.h>

@implementation AudioTrackMetadata {

}

+ (AudioTrackMetadata *)getMetadataForURL:(NSURL *)url {
    auto metadata = SFB::Audio::Metadata::CreateMetadataForURL((__bridge CFURLRef)url);
    auto m = [[AudioTrackMetadata alloc] init];
    if(metadata) {
        auto pictures = metadata->GetAttachedPictures();
        if(!pictures.empty()) {
            m.albumArt = [[NSImage alloc] initWithData:(__bridge NSData *)pictures.front()->GetData()];
        }
        if(metadata->GetTitle()) {
            m.title = (__bridge NSString *) metadata->GetTitle();
        }
        if(metadata->GetArtist()) {
            m.artist = (__bridge NSString *) metadata->GetArtist();
        }
    }
    return m;
}

@end
//
// Created by Christopher Micali on 12/31/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface ArtworkImageView : NSImageView <NSDraggingSource>

@property (copy) NSURL *fileURL;

@end

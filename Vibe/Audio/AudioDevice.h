//
// Created by Christopher Micali on 12/28/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface AudioDevice : NSObject

@property (nonatomic, copy)     NSString *name;
@property (nonatomic, copy)     NSString *uid;
@property (assign)              NSInteger deviceId;
@property (assign)              BOOL isSystemDefault;
@property (nonatomic, strong)   NSArray<NSNumber *>* supportedOutputSampleRates;

@end

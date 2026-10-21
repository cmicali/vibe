//
//  NSURL+FilenameTitle.m
//  Vibe
//

#import "NSURL+FilenameTitle.h"

@implementation NSURL (FilenameTitle)

- (NSString *)filenameTitle {
    NSString *name = self.lastPathComponent.stringByDeletingPathExtension;
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

@end

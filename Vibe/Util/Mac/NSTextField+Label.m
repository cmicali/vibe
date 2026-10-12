//
//  NSTextField+Label.m
//  Vibe
//

#import "NSTextField+Label.h"

@implementation NSTextField (Label)

+ (instancetype)labelWithFrame:(NSRect)frame {
    NSTextField *field = [[self alloc] initWithFrame:frame];
    field.editable = NO;
    field.selectable = NO;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = NO;
    return field;
}

@end

//
//  OpenURLSheetController.m
//  Vibe (iOS)
//

#import "OpenURLSheetController.h"

#import "LinkRules.h"
#import "VibeStrings.h"

// TRAP: the system draws its Paste control blank, and ignores taps on it,
// when its content does not fit the frame. A fixed size fits only the default
// text size. So Open URL's control scales with Dynamic Type, and it spans the
// field so every language's label fits.
static CGFloat VibePasteControlHeight(void) {
    return ceil([UIFontMetrics.defaultMetrics scaledValueForValue:44]);
}

@interface OpenURLSheetController () <UIAdaptivePresentationControllerDelegate, UITextViewDelegate>
@end

@implementation OpenURLSheetController {
    void (^_open)(NSString *text);
    dispatch_block_t _cancel;
    UINavigationController *_sheet;
    UITextView *_field;
    UIBarButtonItem *_openItem;
    UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithOpen:(void (^)(NSString *text))openBlock cancel:(dispatch_block_t)cancelBlock {
    self = [super init];
    if (!self) {
        return nil;
    }
    _open = [openBlock copy];
    _cancel = [cancelBlock copy];

    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UITextView *field = [[UITextView alloc] init];
    field.font = font;
    field.adjustsFontForContentSizeCategory = YES;
    field.keyboardType = UIKeyboardTypeURL;
    field.textContentType = UITextContentTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyGo;
    field.backgroundColor = UIColor.tertiarySystemFillColor;
    field.layer.cornerRadius = 10;
    field.textContainerInset = UIEdgeInsetsMake(8, 4, 8, 4);
    field.accessibilityLabel = STR_LINK_PROMPT_TITLE;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;

    UIPasteControlConfiguration *configuration = [[UIPasteControlConfiguration alloc] init];
    configuration.displayMode = UIPasteControlDisplayModeIconAndLabel;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:configuration];
    paste.target = field;
    paste.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.hidesWhenStopped = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;

    UIViewController *content = [[UIViewController alloc] init];
    content.view.backgroundColor = UIColor.systemBackgroundColor;
    content.navigationItem.title = STR_LINK_PROMPT_TITLE;
    content.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelSheet)];
    UIBarButtonItem *open = [[UIBarButtonItem alloc] initWithTitle:STR_BUTTON_OPEN
                                                             style:UIBarButtonItemStyleProminent
                                                            target:self
                                                            action:@selector(openFromSheet)];
    open.enabled = NO;
    content.navigationItem.rightBarButtonItem = open;
    for (UIView *view in @[field, paste, spinner]) {
        [content.view addSubview:view];
    }
    UILayoutGuide *margins = content.view.layoutMarginsGuide;
    CGFloat fieldHeight = ceil(3 * font.lineHeight) + 16;
    CGFloat pasteHeight = VibePasteControlHeight();
    [NSLayoutConstraint activateConstraints:@[
        [field.topAnchor constraintEqualToAnchor:content.view.safeAreaLayoutGuide.topAnchor constant:8],
        [field.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [field.heightAnchor constraintEqualToConstant:fieldHeight],
        [paste.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:12],
        [paste.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [paste.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [paste.heightAnchor constraintEqualToConstant:pasteHeight],
        // In the field's corner, so the Paste spans the field.
        [spinner.bottomAnchor constraintEqualToAnchor:field.bottomAnchor constant:-8],
        [spinner.trailingAnchor constraintEqualToAnchor:field.trailingAnchor constant:-8],
    ]];

    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:content];
    sheet.modalPresentationStyle = UIModalPresentationFormSheet;
    // The bar, the field, and the Paste row, with a margin under it.
    CGFloat height = 56 + 8 + fieldHeight + 12 + pasteHeight + 20;
    sheet.preferredContentSize = CGSizeMake(540, height);
    sheet.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent
            customDetentWithIdentifier:nil
                              resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
        return height;
    }]];
    sheet.presentationController.delegate = self;
    _sheet = sheet;
    _field = field;
    _openItem = open;
    _spinner = spinner;
    return self;
}

- (void)presentFrom:(UIViewController *)presenter {
    UITextView *field = _field;
    [presenter presentViewController:_sheet animated:YES completion:^{
        [field becomeFirstResponder];
    }];
}

- (void)openFromSheet {
    if (_openItem.isEnabled) {
        _open(_field.text);
    }
}

- (void)cancelSheet {
    _cancel();
}

// A swipe down closed the sheet.
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController == _sheet) {
        [self cancelSheet];
    }
}

// TRAP: dismissed by its presenter. Asked of the sheet itself, a dismiss
// closes only an alert it presents.
- (void)dismissThen:(nullable dispatch_block_t)then {
    UIViewController *presenter = _sheet.presentingViewController;
    if (presenter && !_sheet.isBeingDismissed) {
        [presenter dismissViewControllerAnimated:YES completion:then];
    }
    else if (then) {
        then();
    }
}

- (void)setResolving:(BOOL)resolving {
    _resolving = resolving;
    [self syncSheet];
}

// Open needs a link in the field.
- (void)syncSheet {
    BOOL resolving = _resolving;
    _field.editable = !resolving;
    _field.textColor = resolving ? UIColor.secondaryLabelColor : UIColor.labelColor;
    _openItem.enabled = !resolving && !VibeLinkTextIsBlank(_field.text);
    if (resolving) {
        [_spinner startAnimating];
    }
    else {
        [_spinner stopAnimating];
    }
}

- (BOOL)textView:(UITextView *)textView
        shouldChangeTextInRanges:(NSArray<NSValue *> *)ranges
                 replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        [self openFromSheet];
        return NO;
    }
    return YES;
}

// A link has no line breaks, so a paste's are dropped. The resolve trims the
// ends.
- (void)textViewDidChange:(UITextView *)textView {
    NSString *text = textView.text;
    NSString *joined = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@""];
    if (joined.length != text.length) {
        textView.text = joined;
    }
    [self syncSheet];
}

#if DEBUG
- (UITextView *)debugField {
    return _field;
}

- (BOOL)debugOpenEnabled {
    return _openItem.isEnabled;
}
#endif

@end

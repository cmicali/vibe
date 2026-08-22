//
//  SettingsChoiceViewController.m
//  Vibe (iOS)
//
//  See SettingsChoiceViewController.h.
//

#import "SettingsChoiceViewController.h"

static NSString *const kChoiceCellIdentifier = @"choice";

@implementation SettingsChoiceViewController {
    NSArray<NSString *> *_choices;
    NSInteger            _selectedIndex;
    void               (^_onSelect)(NSInteger index);
}

- (instancetype)initWithTitle:(NSString *)title
                      choices:(NSArray<NSString *> *)choices
                selectedIndex:(NSInteger)selectedIndex
                     onSelect:(void (^)(NSInteger index))onSelect {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        _choices = [choices copy];
        _selectedIndex = selectedIndex;
        _onSelect = [onSelect copy];
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_choices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = _choices[(NSUInteger)indexPath.row];
    cell.contentConfiguration = content;
    cell.accessoryType = indexPath.row == _selectedIndex ? UITableViewCellAccessoryCheckmark
                                                         : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == _selectedIndex) {
        return;
    }
    _selectedIndex = indexPath.row;
    // The whole section, so the checkmark leaves the row it was on.
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
             withRowAnimation:UITableViewRowAnimationNone];
    if (_onSelect) {
        _onSelect(indexPath.row);
    }
}

@end

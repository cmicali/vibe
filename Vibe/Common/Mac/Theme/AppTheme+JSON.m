//
//  AppTheme+JSON.m
//  Vibe
//

#import "AppThemeInternal.h"

@implementation AppTheme (JSON)

// group → {json key → field key}, the import side.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ThemeJSONGroups(void) {
    static NSDictionary *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
            NSMutableDictionary *group = map[spec[kSpecGroup]]
                    ?: (map[spec[kSpecGroup]] = [NSMutableDictionary dictionary]);
            NSCAssert(!group[spec[kSpecJSONKey]], @"%@.%@ mapped twice",
                      spec[kSpecGroup], spec[kSpecJSONKey]);
            group[spec[kSpecJSONKey]] = spec[kSpecKey];
        }
        groups = [map copy];
    });
    return groups;
}

// The editor's section order, as the rows first name the groups.
static NSArray<NSString *> *ThemeJSONGroupOrder(void) {
    return [NSOrderedSet orderedSetWithArray:[VibeThemeFieldSpecs() valueForKey:kSpecGroup]].array;
}

// field key → [group, json key], the export side.
static NSDictionary<NSString *, NSArray<NSString *> *> *ThemeJSONFieldLocations(void) {
    static NSDictionary *locations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
            map[spec[kSpecKey]] = @[spec[kSpecGroup], spec[kSpecJSONKey]];
        }
        locations = [map copy];
    });
    return locations;
}

// Far above any real theme; a mispicked video fails before the parser.
static const NSUInteger kThemeJSONByteCap = 64 * 1024;

// Trimmed, not sanitized, so a bare archive entry name survives where the
// gate drops it.
+ (NSDictionary<NSString *, NSString *> *)rawImageReferencesInJSONData:(NSData *)json {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    NSMutableDictionary<NSString *, NSString *> *references = [NSMutableDictionary dictionary];
    for (NSString *key in VibeThemeImageFieldKeys()) {
        NSArray<NSString *> *location = ThemeJSONFieldLocations()[key];
        id group = [root isKindOfClass:NSDictionary.class] ? root[location[0]] : nil;
        NSString *art = VibeTrimmedCappedString(
                [group isKindOfClass:NSDictionary.class] ? group[location[1]] : nil);
        if (art.length) {
            references[key] = art;
        }
    }
    return references;
}

+ (NSDictionary<NSString *, id> *)recordFromJSONData:(NSData *)data
                                                name:(NSString **)outName
                                               error:(NSError **)error {
    if (outName) {
        *outName = nil;
    }
    if (data.length == 0 || data.length > kThemeJSONByteCap) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:1 userInfo:nil];
        }
        return nil;
    }
    NSError *parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:2 userInfo:
                    parseError ? @{NSUnderlyingErrorKey: parseError} : nil];
        }
        return nil;
    }
    if (outName && [parsed[kVibeThemeRecordNameKey] isKindOfClass:NSString.class]) {
        *outName = parsed[kVibeThemeRecordNameKey];
    }
    // Anything outside a known group key drops, like an unknown field.
    NSMutableDictionary *flat = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *groups = ThemeJSONGroups();
    for (NSString *group in groups) {
        NSDictionary *sub = parsed[group];
        if (![sub isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [groups[group] enumerateKeysAndObjectsUsingBlock:
                ^(NSString *jsonKey, NSString *fieldKey, BOOL *stop) {
            id value = sub[jsonKey];
            if (value) {
                flat[fieldKey] = value;
            }
        }];
    }
    id version = parsed[@"version"];
    BOOL current = [version isKindOfClass:NSNumber.class] && [version integerValue] >= kVibeThemeRecordVersion;
    return [self sanitizedRecord:current ? flat : [self recordUpgradedFromVersion1:flat]];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record name:(NSString *)name {
    return [self JSONDataForRecord:record name:name entryNames:nil];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                    entryNames:(NSDictionary<NSString *, NSString *> *)entryNames {
    NSDictionary *fields = [self sanitizedRecord:record];
    if (entryNames.count) {
        NSMutableDictionary *renamed = [fields mutableCopy];
        [entryNames enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *entry, BOOL *stop) {
            renamed[key] = entry;
        }];
        fields = renamed;
    }
    NSMutableDictionary<NSString *, NSMutableDictionary *> *grouped = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSArray<NSString *> *> *locations = ThemeJSONFieldLocations();
    for (NSString *fieldKey in fields) {
        NSArray<NSString *> *location = locations[fieldKey];
        NSMutableDictionary *sub = grouped[location[0]]
                ?: (grouped[location[0]] = [NSMutableDictionary dictionary]);
        sub[location[1]] = fields[fieldKey];
    }
    // Hand-assembled: NSJSONSerialization cannot order top-level keys.
    NSMutableString *out = [NSMutableString stringWithFormat:@"{\n  \"version\" : %ld", (long)kVibeThemeRecordVersion];
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:(name ?: @"")
            options:NSJSONWritingFragmentsAllowed error:NULL];
    [out appendFormat:@",\n  \"name\" : %@",
            [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding]];
    for (NSString *group in ThemeJSONGroupOrder()) {
        if (!grouped[group].count) {
            continue;  // the empty record — vibe.json — stays version + name alone
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:grouped[group]
                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [out appendFormat:@",\n  \"%@\" : %@", group,
                [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\n  "]];
    }
    [out appendString:@"\n}"];
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}

@end

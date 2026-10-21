//
//  NSBundle+BuildInfo.m
//  Vibe
//

#import "NSBundle+BuildInfo.h"
#import "VibeMacros.h"

// generate-git-info.sh writes it, in a pre-build phase of the app's. Without
// it, the git fields read as unknown.
#if __has_include("VibeGitInfo.h")
#import "VibeGitInfo.h"
#else
#define VIBE_GIT_COMMIT "unknown"
#define VIBE_GIT_BRANCH "unknown"
#define VIBE_GIT_DIRTY  0
#endif

void VibeLogBuildProvenance(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    LogInfo(@"    Source: %@", bundle.vibeGitString);
    LogInfo(@"     Built: %@", bundle.vibeBuildTimeString);
}

@implementation NSBundle (BuildInfo)

// Not localized: a diagnostic string.
- (NSString *)vibeVersionString {
#if DEBUG
    NSString *configuration = @"Debug";
#else
    NSString *configuration = @"Release";
#endif
    NSDictionary *info = self.infoDictionary;
    return [NSString stringWithFormat:@"%@ (%@) · %@",
                                      info[@"CFBundleShortVersionString"] ?: @"?",
                                      info[@"CFBundleVersion"] ?: @"?",
                                      configuration];
}

- (NSString *)vibeGitString {
    NSString *commit = @VIBE_GIT_COMMIT;
    if ([commit isEqualToString:@"unknown"]) {
        return @"unknown (not a git checkout)";
    }
    return [NSString stringWithFormat:@"%@ (%s%@)",
                                      commit,
                                      VIBE_GIT_BRANCH,
                                      VIBE_GIT_DIRTY ? @", dirty" : @""];
}

- (NSString *)vibeBuildTimeString {
    NSString *executablePath = self.executablePath;
    if (!executablePath) {
        return @"unknown";
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:executablePath
                                                                               error:nil];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!modified) {
        return @"unknown";
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; // fixed format, not the user's
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";
    return [formatter stringFromDate:modified];
}

@end

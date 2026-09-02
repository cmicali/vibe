//
//  MusicalKey.h
//  Vibe
//
//  The musical-key representation shared by the key analyzer, the tagged-key
//  parser, the header label and the Settings notation choice. Header-only
//  static inlines, like FLACConvertRules.h, so the unit tests compile it
//  without the analyzer or TagLib.
//
//  A key is one NSInteger: pitch class 0-11 (C..B) for a major key, 12 +
//  pitch class for a minor one, VibeMusicalKeyNone when unknown. The compact
//  encoding rides the waveform cache archive, so it must stay stable.
//
//  Display names are notation, not prose: they use the spellings DJ software
//  standardized around the Camelot wheel (Db major but C#m, Eb/Ab/Bb
//  elsewhere) and are deliberately not localized.
//

#import <Foundation/Foundation.h>

typedef NSInteger VibeMusicalKey;

// TRAP: 0 is C major, not "none". A fresh holder must be set to this
// explicitly — a zero-filled ivar or a message to nil reads as tagged C major.
static const VibeMusicalKey VibeMusicalKeyNone = -1;

static inline BOOL VibeMusicalKeyIsValid(VibeMusicalKey key) {
    return key >= 0 && key < 24;
}

static inline BOOL VibeMusicalKeyIsMinor(VibeMusicalKey key) {
    return key >= 12 && key < 24;
}

static inline VibeMusicalKey VibeMusicalKeyMake(NSInteger pitchClass, BOOL minor) {
    if (pitchClass < 0 || pitchClass > 11) {
        return VibeMusicalKeyNone;
    }
    return pitchClass + (minor ? 12 : 0);
}

static inline NSInteger VibeMusicalKeyPitchClass(VibeMusicalKey key) {
    return VibeMusicalKeyIsValid(key) ? key % 12 : -1;
}

// Camelot wheel positions, indexed by pitch class. Minor keys are the A ring,
// major the B ring; adjacent numbers are a fifth apart and mix harmonically.
static inline NSInteger VibeMusicalKeyCamelotNumber(VibeMusicalKey key) {
    static const int kMajor[12] = {8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1};
    static const int kMinor[12] = {5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10};
    if (!VibeMusicalKeyIsValid(key)) {
        return 0;
    }
    NSInteger pc = key % 12;
    return VibeMusicalKeyIsMinor(key) ? kMinor[pc] : kMajor[pc];
}

// "8A" / "8B". Empty string when the key is unknown, so a caller can bind a
// label's text unconditionally.
static inline NSString *VibeMusicalKeyCamelotName(VibeMusicalKey key) {
    if (!VibeMusicalKeyIsValid(key)) {
        return @"";
    }
    return [NSString stringWithFormat:@"%ld%@", (long)VibeMusicalKeyCamelotNumber(key),
            VibeMusicalKeyIsMinor(key) ? @"A" : @"B"];
}

// "Am" / "Db". Camelot-wheel spellings: flats for the major ring's black keys
// except F#, and C#m/F#m against Ebm/Abm/Bbm on the minor ring.
static inline NSString *VibeMusicalKeyMusicalName(VibeMusicalKey key) {
    static NSString *const kMajor[12] =
            {@"C", @"Db", @"D", @"Eb", @"E", @"F", @"F#", @"G", @"Ab", @"A", @"Bb", @"B"};
    static NSString *const kMinor[12] =
            {@"Cm", @"C#m", @"Dm", @"Ebm", @"Em", @"Fm", @"F#m", @"Gm", @"Abm", @"Am", @"Bbm", @"Bm"};
    if (!VibeMusicalKeyIsValid(key)) {
        return @"";
    }
    NSInteger pc = key % 12;
    return VibeMusicalKeyIsMinor(key) ? kMinor[pc] : kMajor[pc];
}

// Parses the free-text key strings found in real tags: musical names in any
// common spelling ("Am", "F#m", "Bbm", "A minor", "Cmaj", German "H"),
// Camelot ("8A", "08a") and Traktor's Open Key ("1d", "10m"). Returns
// VibeMusicalKeyNone for anything it cannot read with confidence — an
// unparseable tag falls back to analysis rather than guessing.
static inline VibeMusicalKey VibeMusicalKeyFromString(NSString *raw) {
    if (raw.length == 0) {
        return VibeMusicalKeyNone;
    }
    NSString *s = [raw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    s = [s stringByReplacingOccurrencesOfString:@"♯" withString:@"#"];
    s = [s stringByReplacingOccurrencesOfString:@"♭" withString:@"b"];
    if (s.length == 0 || s.length > 16) {
        return VibeMusicalKeyNone;
    }

    // Camelot ("8A") and Open Key ("8d"/"8m"): digits then one ring letter.
    unichar last = [s characterAtIndex:s.length - 1];
    if (last >= '0' && last <= '9') {
        return VibeMusicalKeyNone; // "42", or a plain number — not a key
    }
    NSUInteger digits = 0;
    while (digits < s.length - 1) {
        unichar c = [s characterAtIndex:digits];
        if (c < '0' || c > '9') {
            break;
        }
        digits++;
    }
    if (digits > 0 && digits == s.length - 1) {
        NSInteger n = [s substringToIndex:digits].integerValue;
        if (n < 1 || n > 12) {
            return VibeMusicalKeyNone;
        }
        // Pitch class per ring position 1..12.
        static const int kCamelotMinorPC[12] = {8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1};
        static const int kCamelotMajorPC[12] = {11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4};
        static const int kOpenKeyMajorPC[12] = {0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5};
        static const int kOpenKeyMinorPC[12] = {9, 4, 11, 6, 1, 8, 3, 10, 5, 0, 7, 2};
        switch ([s characterAtIndex:s.length - 1]) {
            case 'A': case 'a': return VibeMusicalKeyMake(kCamelotMinorPC[n - 1], YES);
            case 'B': case 'b': return VibeMusicalKeyMake(kCamelotMajorPC[n - 1], NO);
            case 'D': case 'd': return VibeMusicalKeyMake(kOpenKeyMajorPC[n - 1], NO);
            case 'M': case 'm': return VibeMusicalKeyMake(kOpenKeyMinorPC[n - 1], YES);
            default: return VibeMusicalKeyNone;
        }
    }

    // Musical name: note letter, optional accidental, optional mode word.
    unichar note = [s characterAtIndex:0];
    NSInteger pc;
    switch (note) {
        case 'C': case 'c': pc = 0;  break;
        case 'D': case 'd': pc = 2;  break;
        case 'E': case 'e': pc = 4;  break;
        case 'F': case 'f': pc = 5;  break;
        case 'G': case 'g': pc = 7;  break;
        case 'A': case 'a': pc = 9;  break;
        case 'B': case 'b': pc = 11; break;
        case 'H': case 'h': pc = 11; break; // German B natural
        default: return VibeMusicalKeyNone;
    }
    NSUInteger i = 1;
    if (i < s.length) {
        unichar acc = [s characterAtIndex:i];
        if (acc == '#') {
            pc = (pc + 1) % 12;
            i++;
        }
        else if (acc == 'b') {
            pc = (pc + 11) % 12;
            i++;
        }
    }
    NSString *mode = [[[s substringFromIndex:i] lowercaseString]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
    mode = [mode stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (mode.length == 0 || [mode isEqualToString:@"maj"] || [mode isEqualToString:@"major"]
            || [mode isEqualToString:@"dur"]) {
        return VibeMusicalKeyMake(pc, NO);
    }
    if ([mode isEqualToString:@"m"] || [mode isEqualToString:@"mi"] || [mode isEqualToString:@"min"]
            || [mode isEqualToString:@"minor"] || [mode isEqualToString:@"moll"]) {
        return VibeMusicalKeyMake(pc, YES);
    }
    return VibeMusicalKeyNone;
}

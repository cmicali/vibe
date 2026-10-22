//
//  AudioAnalysisObserversTests.m
//  VibeTests
//
//  How Vibe reads its tempo and key from a decode's results. A bad value
//  degrades to unknown. The entry files it as it came, which vibe-libs'
//  CodableAudioWaveformTests checks.
//

#import <XCTest/XCTest.h>
#import "AudioAnalysisObservers.h"

@interface AudioAnalysisObserversTests : XCTestCase
@end

@implementation AudioAnalysisObserversTests

- (void)testNonFiniteOrNegativeBPMIsCoercedToZero {
    NSString *tempo = AudioBPMAnalyzer.waveformObserver.identifier;
    for (id bad in @[@((float)NAN), @((float)INFINITY), @-5.0f, @0.0f, @"128", @[@128]]) {
        XCTAssertEqual([AudioBPMAnalyzer tempoInResults:@{tempo: bad}], 0.0f, @"bpm %@ must coerce to zero", bad);
    }
    XCTAssertEqual([AudioBPMAnalyzer tempoInResults:@{tempo: @128.0f}], 128.0f);
}

- (void)testAbsentKeyDecodesAsNone {
    // Not the 0 an integer decode fabricates, which is C major.
    NSString *tempo = AudioBPMAnalyzer.waveformObserver.identifier;
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{tempo: @120.0f}], VibeMusicalKeyNone);
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{}], VibeMusicalKeyNone);
}

- (void)testOutOfRangeOrWrongClassKeyIsCoercedToNone {
    // 0 is a valid key (C major), so the coercion must come from range and
    // class checks, never from a nil-ish read.
    NSString *key = AudioKeyAnalyzer.waveformObserver.identifier;
    for (id bad in @[@(24), @(-2), @(3.5), @"8A", @[@(3)]]) {
        XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{key: bad}], VibeMusicalKeyNone, @"key %@ must coerce to none", bad);
    }
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{key: @(0)}], 0, @"C major is preserved, not mistaken for absent");
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{key: @(9)}], 9);
}

@end

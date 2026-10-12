# Unit tests

`make test` runs `VibeTests` (always Debug) and the cloud-runner oracle tests (`check-cloud-scenarios`). `make test-audio` runs `VibeAudioTests` (below). Both targets are defined in `project.yml`, so editing a source list means re-running `xcodegen generate`.

`iOSDriver/` is **not** a test suite. It is the `vibe-debug` skill's touch driver, a resident XCUITest (`VibeiOSDriver`) started by `drive-ios.sh`, and `VibeTests`' `Tests` source entry excludes it. `BenchComponents/` is the `vibe-perf` skill's benchmark tool, excluded the same way.

**The directories mirror `Vibe/`.** A test lives in the directory of the code it tests: `Audio/` (with `Analysis/`, `FX/`, `Levels/`, `Metadata/`, and `Waveform/`), `Loading/` (with `Net/`), `Playlist/`, `WaveformUI/`, `Common/`, `Util/`, `Controls/`, `NowPlaying/`, `Mac/`, and `iOS/`. A subsystem's platform half shares its directory. So `Audio/` holds the device and FLAC conversion tests, and `Playlist/` holds the drag rules. A test of a debug seam sits beside the tests of the class the seam opens (`AudioLoadingConfigurationDebugTests`). `Debug/` holds the tests of the debug fakes. The Dropbox tests are in `iOS/`, beside the Dropbox code. `SmokeTests.m` stays at the root, because it tests the harness itself.

## Helpers

`Support/` holds the shared helpers. None of them runs a test.

- `AudioFixtures.h`: the fixture writers and the reference conversion (`VibeReferenceResample`). Both targets use it.
- `DropboxStubProtocol.h` and `.m`: the Dropbox tests' `NSURLProtocol`. One handler the test installs answers every request.
- `HTTPStub.h` and `.m`: a scripted HTTP host per instance, over the debug fake's serving engine. Both targets compile it.
- `LinkStoreTestCase.h` and `.m`: the base class of each link host's store tests.
- `MaterializationTestFakes.h` and `.m`: the gated dataless probe and the hand-completed provider operations of `AudioFileMaterializationCoordinatorTests`.
- `MetadataLoaderTestFakes.h` and `.m`: the metadata loader tests' fakes, and the suite's `AudioTrackMetadata` decoy.
- `TestFilesystemGuard.h` and `.m`: the per-process temp root and in-memory defaults, installed at image load. Both targets compile it.
- `VibeReadAheadScript.h` and `.m`: forces the network-mount rule and scripts each read. Both targets compile it.

## What belongs here

Deterministic host-less logic and machinery: code whose outcome its inputs or narrow injected I/O boundaries control. That covers math, archive encode and decode, formatting, precedence rules, cache keys, coordinator accounting, queue and retry orchestration, and local temp-file wrappers. The suite is **host-less** (no `TEST_HOST`). It runs in seconds with no window server, audio hardware, permissions or Vibe instance, and it does not inherit the app's sandbox, so it can read fixtures from the repo.

Anything that needs the app running belongs in the `vibe-debug` skill's command channel: shell transport routing, menus, drag and drop, layout, rendering, Now Playing, device switching. Player transport and FX have the device-free audio suite below.

**Where rendering is the whole class, extract the arithmetic into a seam.** Decisions that need no rendering live in header-only `*Rules.h` and `*Math.h` files that the shipping class **calls** rather than restates: `FadeMath.h`, `AudioFXMath.h`, `TransportMath.h`, `NowPlayingRules.h`, `PlayerScreenRules.h`. `AudioVoiceBusTests` tests the voice bus host-less: the tests own the output buffers and call `VibeVoiceBusRender` with inline decoding, so every frame is compared against its file. `AudioVoiceBusPoolTests` covers starvation, kills and the voice pool. Their harness is `AudioVoiceBusTestCase`. `AudioFXChainTests` hosts the FX chain alone and calls `VibeFXChainRender` through the debug pump's frame-driven clock. Reach for these before deciding a class cannot be tested.

**The boundary is uncontrolled I/O.**

- `AudioWaveformLoaderTests` writes a WAV through `AudioFixtures.h` and reads it back through the real loader. It streams one into a part file behind a `CloudFileAvailability`, and runs the real `AudioWaveformCache` over a store in its temp directory (`initWithRootPath:`).
- The Dropbox tests drive the real `DropboxClient` and `DropboxMirror` over `DropboxStubProtocol` and a temp root. `DropboxMirrorTestCase` is their harness and runs no tests. `DropboxMirrorTests` covers listing, search, ranged reads and the account. `DropboxMirrorFetchTests` covers the fetch and resumed downloads. `DropboxMirrorStreamingTests` covers streaming, the tail window and the row's loading bar. Their seam is `DropboxClientInternal.h`: `adoptRefreshToken:accountID:`, plus `useSessionConfiguration:` and `retryDelayScale` from `HTTPTransferClientInternal.h`. `retryDelayScale` makes a scripted drop or 429 wait milliseconds instead of seconds. The debug channel's `VibeFakeDropbox` uses the same seam.
- `HTTPTransferClientTests`, `RemotePlaceholderStoreTests` and `LinkStoreTests` drive their classes over `HTTPStub` and a temp root. `HTTPStub` has its own host per instance. It scripts the answers of the debug fake's serving engine, `VibeFakeHTTPProtocol` (`Vibe/Debug/AGENTS.md`). So the Range rule and body delivery are the debug channel's own. `LinkStoreTestCase` is a harness that runs no tests. Each link host's store tests subclass it in that host's rules file (`DropboxLinkStoreTests`, `GoogleDriveLinkStoreTests`, `ICloudLinkStoreTests`). `answerHost:` lets one stub answer a public name, so a test sees that nothing was sent there. `VibeFakeHTTPTests` drives the debug fake through the plain client and through `LinkStore`.
- The link decisions need no network: `HTTPTransferRulesTests`, `LinkRulesTests` and each host's `*LinkRulesTests`. `FileSearchRulesTests` covers the iOS Files tab's `FileSearchRules.h` from this macOS suite.

**A network mount is forced, never found.** `AudioFileHandleReadAheadTests` reads ahead on files in its own temp directory. It shares `AudioFileHandleStreamingTestCase` with `AudioFileHandleStreamingTests`. `AudioFileHandle+Debug.h` forces the mount rule for those URLs, and its before-read hook scripts each `pread`. `VibeReadAheadScript` (`VibeReadAheadScript.h`) installs both and is the script's shape. It counts reads by file and offset. It can throttle them, stall them from an offset until released (one read at a time if wanted), fail them with an errno once or always, or read nothing once at an offset, as a reconnecting share can. A failure can be held after it is signalled until the test releases it. A stalled read holds its thread as a dead mount's syscall does. Both test targets compile it. **The read-ahead counts are process-wide**, and a stalled thread outlives its handle as an orphan. A class that parks threads releases them in `tearDown` (`releaseEverything`) and waits for `threadsGone` before the next test counts. `AudioFileOpenRulesTests` feeds `VibeMountReadsAhead` a fake `statfs` table and never reads the machine's.

**Test an orchestrator as itself when its nondeterminism has narrow boundaries.** The metadata loader tests run the production queues, barrier, ranking, materialization slots, real coordinator, parse claims, installation, publication and cancellation. It replaces only cache reads, file parsing and the coordinator's provider-operation boundary. Their harness is `AudioTrackMetadataLoaderTestCase`, and each topic is a subclass: `AudioTrackMetadataLoaderTests` (stage one and priority), `…SharedFileTests` and `…RetryTests` (retries, the foreground yield, admission and cancellation). Do not copy the loader's state machine into a fake or flatten it into rule tests. Other examples of the same approach:

- `NowPlayingController` (`NowPlayingRulesTests`): an injected clock and OS sinks, with the real dirty checks and artwork construction.
- `AudioFileConverter`: held file-operation callbacks and the real `NSUndoManager` for undo and redo. Its dormant TagLib functions are fail-loud decoys in `FLACDisposalRulesTests`. Its injected constructor skips the launch-time temp sweep.
- `ArtworkDisplayController` (`AudioTrackTests`): the real single-render, latest-request scheduler with held renderer completions and a publication sink that keeps views and the Dock out.
- `OpenBurstCoalescerTests` runs launch priority through the production launch method. `PlaylistFileTests` round-trips the private session with temp files and isolated defaults.
- `AudioDeviceManagerTests` runs `AudioDeviceManager` with injected enumeration and retry scheduling, with no HAL registration. `CoreAudioUtil`'s `releaseDeviceObligation:attempt:isAbsent:` is tested with controlled attempts.

OS provider state, shell routing, remote-command registration, output rebinding, device property I/O and hardware settlement remain live tests.

**The suite links an incomplete `AudioTrackMetadata` decoy** (`Support/MetadataLoaderTestFakes.m`), because the real one is ObjC++ and TagLib. Its parser constructor raises. Loader fixtures use the copy-capable duck fake, and a newly required selector is added deliberately.

## Rendered audio

`make test-audio` generates deterministic fixtures under `build/audio-fixtures`, self-tests the PCM comparator (`build/verify-bit-perfect`), then runs **VibeAudioTests**. It is host-less and compiles the production player, FX, decoder and loading machinery into its own derived data (`build/AudioDerivedData`), so `make -j2 test test-audio` runs both suites at once. It reuses `TestFilesystemGuard.m`. `make test-audio-summary` reads `build/AudioTestResults.xcresult`.

The suite lives in `AudioRender/`. `AudioPlayerRenderTests` is a base class with no tests, in `AudioPlayerRenderTestCase.h` and `.m`. Each topic is a subclass in its own file of the same name: `AudioPlayerRenderFidelityTests`, `…EdgesTests`, `…StreamTests`, `…ReadAheadTests`, `…EstimatedTests`, `…SignalTests`, `…PipelineTests`, `…DeviceTests`, `…OutputTests`, `…PitchTests` and `…LinkTests`. The parallel runner spreads the subclasses across processes. The slowest subclass sets the suite's wall time. A new test joins its topic's subclass. A subclass that outgrows the others is the one to split. `ARGS=-only-testing:VibeAudioTests/AudioPlayerRenderEdgesTests/testGaplessSplitSignalAcrossRenderBlocks` narrows a run.

`AudioFixtures.h` is the one home of fixture writers and of the reference conversion (`VibeReferenceResample`), shared by both targets. Its writers emit raw RIFF bytes by default, so a fixture never makes `AudioFileHandle` its own decode oracle. The base class is the one home of capture, comparisons and delegate traces. The test constructor attaches `VibeManualRenderPump` in place of the output unit before any voice exists and skips HAL observation. The pump supplies a frame-driven clock or the app's real timer, and voice ramps, FX sweeps and idle stop run their production algorithms on it. Before every frame-driven slice the pump decodes the bus inline, and after every slice it drains it, so a voice is live before the first slice that could render it. File opens and delegate delivery keep their real queues, and bounded event waits settle them between render blocks. No mock renderer, copied transport or UI host is involved.

**The oracle compares every source frame in every channel** after one alignment. With Declick on, only its first 50 ms of startup is excluded. Lossless WAV references come from the fixture bytes, FLAC, ALAC and AIFF references are the original PCM, and lossy formats compare to their decoded PCM. AAC allows four float epsilons (below −126 dBFS), since independent Apple decodes may round differently; every other codec is exact. Captures must hold complete frames and no audio after the reference ends. The corruption tests reject dropped or duplicated frames, channel swaps, polarity or gain changes, clipping, silence, NaNs, single-LSB changes, truncation and short matching excerpts.

**Bit-perfect and FX-free playback require exact float samples, and so does a dormant FX chain** with the meter installed (`testEveryReleasedEffectRestsAndReplaysTheFileExactly`). **Never loosen that to a tolerance.** A low kill left as a flat biquad instead of rested differs by about `7e-13`, which only an exact comparison sees. A float32 reference cannot show what float32 dropped, so wider sources are also compared at full width (`VibeCompareWidePCM`). SRC asserts gain within 0.01 dB, duration and an alias ceiling of −90 dBFS. Active FX assert their frequency response, echo timing, decay and finite output.

**Coverage spans** transport (start paused, stop and replay, idle shutdown, seeks, mode and format changes, interrupted fades, skip storms, a starved decoder), the varispeed, output rate changes, the idle stop and `outputIdle`, the meter's reinstall, stuck renders and stalled reads, a failed or late output unit, gapless splits at awkward boundaries, and conversions against `VibeReferenceResample`. Each test names its case. Two techniques recur:

- **A file still downloading** is a remote placeholder whose fetch the test writes (`streamingCopyOf:`, `…StreamTests`). **A file on a network mount** is a forced, scripted read-ahead (`networkCopyOf:`, `…ReadAheadTests`). Both play on the decode pool, since the inline fill would block on a waiting read. **A link** plays through the real `LinkStore` over `HTTPStub` (`…LinkTests`).
- **Threading changes run under ThreadSanitizer.** Run `AudioVoiceBusTests`, `AudioVoiceBusPoolTests` and the whole render suite with `-enableThreadSanitizer YES -enableCodeCoverage NO` and a separate derived-data path. A test's own cross-thread flag must be atomic, or it reads as a race there.

A failed PCM comparison attaches the reference, the capture, aligned difference WAVs and the event and pipeline state to the result bundle. Metric assertions include their measured values.

The fixture generator's `--render-tests` mode owns the source corpus; tests only create temporary slices and malformed inputs. Stock macOS encoders cover the core formats, CAF and W64 included. MP3, MP2, QTA and Ogg need ffmpeg and are skipped without it; CI installs it. The ISO/IEC 11172-4 Layer III compliance stream and its reference decode are ISO's, so the generator fetches them from FFmpeg's FATE mirror and checks pinned hashes. When that fails, `testDrMP3PassesTheISOComplianceStreamAtFullAccuracy` skips.

The pump proves the software path, **not** DAC samples, hardware negotiation, exclusivity or iOS session recovery. `make test-audio-loopback` and `make test-audio-device` opt into the `vibe-debug` verifier for those macOS boundaries. Hardware is never a CI prerequisite.

## Rules that are easy to get wrong

**The suite must leave no trace on the developer's machine, and `TestFilesystemGuard.m` makes that true.** Host-less means unsandboxed, so every standard user directory a production path resolves is the developer's real one. `AppTheme`'s artwork store would land in `~/Library/Application Support/<main bundle identifier>/ThemeArt`, where the main bundle is the XCTest tool. Standard defaults would be the XCTest tool's domain, shared with every other test process on the machine. The guard runs at **image load**, before XCTest builds a case. It makes a per-pid temp root, points `VIBE_THEME_ART_DIR` inside it, and makes `+[NSUserDefaults standardUserDefaults]` answer an in-memory store of the process's own. It removes the root at exit. A crashed or killed process never reaches exit, so each process first removes the roots of dead pids, and its own pid's root, which a reused pid may have left. A test wanting a fresh store allocates `VibeTestUserDefaults` (`TestFilesystemGuard.h`). **TRAP: in memory, not a cfprefsd suite, even a per-pid one.** On CI a suite key froze at its first value for seconds. It is not a `setUp`, because a guarantee each class opts into is one a new class silently opts out of.

**That per-process isolation is what lets both suites run in parallel** (the schemes' `parallelizable`). Classes spread across runner processes, and one process's `AppSettings` writes must not reach another's reads. A new cross-process resource (a fixed temp name, a named defaults suite, a real `~/Library` path) breaks that. Use UUID or per-pid names only.

**TRAP: a test narrowing the artwork path must restore the previous value, never `unsetenv` it** (`AppThemeTestCase`). Unset hands every later test the real `~/Library`, and the leak surfaces under whichever class runs next. **Saving and restoring a setting around a test does not return it to unset.** Reading an unset key answers the registered default, so writing it back stores a key that was never there.

**A bounded wait is a hang guard, a gate or a negative check, and only the last is short.**

- A wait for something that must happen (an expectation, an asserted semaphore, a poll's deadline) uses `VIBE_TEST_HANG_TIMEOUT` from `project.yml`, never a literal. Under parallel classes and `make -j2`, utility-QoS work goes unscheduled for seconds.
- A gate the test releases itself (a fake blocked on a semaphore, or a pending grace the test settles, as in `AudioWorkSchedulerTests`) uses `VIBE_TEST_GATE_TIMEOUT`, which outlasts the guards the test waits on while holding it.
- A negative check (an inverted expectation, a fixed window before asserting nothing arrived) stays short, since every pass runs its full length.
- A fixed window before asserting something did arrive is the flaky shape. Poll up to the guard instead.
- An elapsed-time assertion never reads the test thread's clock, which is late by however long that thread was descheduled. Measure between stamps taken where the code under test runs, on the clock its timer uses (`testProductionGatedTimerReopensADatalessScanAfterForegroundRelease`).
- A timer the code under test arms and the test does not wait for (a retry seconds out) is a boundary to replace, like an I/O one (`testFailedDeviceSwitchReconcilesOutputGraph`'s bind retry).

**A fixture's size on disk says nothing about its length.** The generator writes files whose declared content dwarfs their bytes, so a seek past a 32-bit frame count can be tested. `flac-long.flac` is under a megabyte and 4.3 billion frames. Anything that decodes a fixture to its end, or times a pass over one, reads the header's frame count first. A full decode of such a file runs for hours.

**Never put test files under `Vibe/`.** Both app targets recurse whole shared subsystem directories, so a test file there is compiled into both shipping apps. `Tests/` is named by no app target.

**Sources under test are compiled into the test target, not linked from the app.** A test for a new file adds that file to a source list in `project.yml`. A file both test targets compile goes in the `hostless-test-sources` template. A file only one target compiles goes in that target's own list. Keep the lists curated, and keep TagLib out of them.

**Where a test needs an `AudioTrackMetadata`, use a duck-typed fake cast to the property type.** `AudioTrackTests.m` declares `FakeTrackMetadata : NSObject` and installs it through `AudioTrackInternal.h`. `AudioTrack` only sends messages to its metadata and never names the class.

**Share a private method under test through an `*Internal.h` the implementation imports too** (`NSURLUtilInternal.h`), never by re-declaring selectors in the test. A rename then breaks the build instead of the run.

**A temp-directory fixture has two spellings, and both turn up.** `NSTemporaryDirectory()` returns `/var/folders/…`, and `/var` is a symlink to `/private/var`. A directory walk answers in the resolved form, while standardizing a path drops the `/private` prefix again. `URLByResolvingSymlinksInPath` leaves the temp directory's prefix as it found it. Use `realpath(3)` on the fixture root at setup, and be ready to strip either spelling when comparing (`NSURLUtilTests.m`).

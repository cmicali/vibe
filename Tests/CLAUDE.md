# Unit tests

`make test` runs these (always Debug). The `VibeTests` target is defined in `project.yml`; editing its source list means re-running `xcodegen generate`.

`iOSDriver/` is **not** part of this suite — it is the `vibe-debug` skill's interactive touch driver, a resident XCUITest started by `drive-ios.sh` and never run as a test. It has its own target (`VibeiOSDriver`) and is excluded from `VibeTests`' `Tests` source entry.

## What belongs here

Deterministic host-less logic and machinery only — code whose outcome is controlled by its inputs or narrow injected I/O boundaries and needs no running app: sample and geometry math, archive encode/decode and validation, string and duration formatting, precedence and fallback rules, cache-key derivation, coordinator accounting, queue/barrier/retry orchestration, and local temporary-file wrappers. The suite is **host-less** (no `TEST_HOST`), so it runs in seconds with no window server, no audio hardware, no permissions and no Vibe instance — and it does not inherit the app's sandbox, which is what lets it read fixtures from the repo.

Anything that needs the app running — transport, FX, menus, drag-and-drop, layout, rendering, Now Playing, device switching — belongs in the `vibe-debug` skill's command channel instead, which drives a live app and reads back state as JSON.

**Where the engine is the whole class, extract the arithmetic into a seam.** `AudioPlayer` and `AudioFX` own `AVAudioEngine` graphs and are unreachable from a host-less suite, so their decisions live in header-only `*Rules.h` / `*Math.h` files that the shipping class **calls** rather than restates: `FadeMath.h` (`VibeIncomingFadeMilliseconds`, `VibeFadeStepsForMilliseconds`, called from `AudioPlayer.m` and `+Fades.m`), `AudioFXMath.h` (called from `AudioFX.m`), `GaplessSpliceMath.h`, `TransportMath.h`, `NowPlayingRules.h`, `PlayerScreenRules.h`. Reach for that before concluding a class cannot be tested.

**The line is the engine, not the framework.** `AVFAudioWaveformLoaderTests` writes a WAV with `AVAudioFile` and reads it back through the real loader — `AVAudioFile` is file I/O with no engine, no device and nothing to configure. `AVAudioEngine` is the other side of that line and stays out.

**Test an orchestrator as itself when its nondeterminism has narrow boundaries.** `AudioTrackMetadataLoaderTests` runs the production queues, stage-one barrier, ranking, materialization slots, real coordinator, parse claims, installation, publication and cancellation while replacing only cache reads, file parsing and the coordinator's provider-operation boundary. Do not copy its state machine into a fake or flatten it into disconnected rule tests: that would stop testing the machinery the live scenario relies on. OS provider state, app-shell routing and AVFoundation playback settlement remain live tests.

The test target deliberately links an incomplete `AudioTrackMetadata` decoy because the real implementation is ObjC++/TagLib. Its real-parser constructor raises; loader fixtures must use the copy-capable duck fake, and any newly required selector must be added deliberately rather than treating the decoy as production metadata.

## Rules that are easy to get wrong

**The suite must leave no trace on the developer's machine, and `TestFilesystemGuard.m` is what makes that true.** Being host-less means being **unsandboxed**, so every standard user directory a production path resolves is the developer's real one: `AppTheme`'s artwork store lands in `~/Library/Application Support/ThemeArt` (a folder whose name does not even say Vibe), and because the suite has no bundle identifier of its own, `AppSettings` writes land in `~/Library/Preferences/com.apple.dt.xctest.tool.plist` — a domain shared with every other XCTest run on the machine. The guard runs at **image load**, before XCTest builds a case: it redirects `VIBE_THEME_ART_DIR` into a per-pid temp root and snapshots the defaults domain, then at exit removes the root and restores the domain exactly as found. It is deliberately not a `setUp` — a suite-wide guarantee each class opts into is one a new class silently opts out of, which is how that folder got created in the first place.

Two traps follow from it. A test narrowing the artwork path for its own isolation must **restore** the previous value, never `unsetenv` it: unsetting hands every later test the real `~/Library`, so the leak surfaces under whichever class runs next rather than the one that caused it (`AppThemeTests`). And **saving and restoring a setting around a test does not keep it off disk** — reading an unset key answers the *registered* default, so writing that value back materializes a key that was never there (`FolderArtWalkTests`). Only the exit-time domain restore can see what any test actually wrote. `testStoredArtworkStaysInTempAndNeverTouchesTheRealLibrary` asserts the artwork half so a removed guard fails loudly instead of quietly writing to `~/Library`.

**Never put test files under `Vibe/`.** Both app targets list whole shared subsystem directories (`- path: Vibe/Audio`, `- path: Vibe/Util`, …), recursed unconditionally — a test file dropped into one is compiled into the shipping binaries of both apps. `/Tests` at the repo root is named by no app target. (`**/*.md` is excluded everywhere, so this file is safe either way.)

**Sources under test are compiled into the test target, not linked from the app.** Adding a test for a new file means adding that file to the `VibeTests` source list in `project.yml`. Keep the list curated, and keep TagLib out of it — nothing here needs it, and the vendored subset would dominate the build.

**Where a test needs an `AudioTrackMetadata`, use a duck-typed fake cast to the property type.** `AudioTrackTests.m` declares `FakeTrackMetadata : NSObject` and installs it through `AudioTrackInternal.h` — `objc_msgSend` does not care about the static type, and `AudioTrack` only ever sends messages to its metadata, never names the class.

**Where the thing under test is a private class method, share it through an `*Internal.h` the implementation file imports too** (`NSURLUtilInternal.h`), rather than re-declaring selectors in the test: a rename then breaks the build instead of the run.

**A temp-directory fixture has two spellings, and both turn up.** `NSTemporaryDirectory()` hands back `/var/folders/…`, `/var` is a symlink to `/private/var`, and a directory walk answers in the resolved form while anything that standardizes a path drops the `/private` prefix again. `URLByResolvingSymlinksInPath` does not settle it — it leaves the temporary directory's prefix as it found it. Use `realpath(3)` on the fixture root at setup and be ready to strip either spelling when comparing (`NSURLUtilTests.m`).

# Future: unit tests for the iOS app shell

**Status: planned, not started (written 2026-10-02).** Deliberately parked until #134 (Dropbox streaming) lands into #132: it rewrites `DropboxMirrorTests`, the materialization coordinator, the cloud registry and the browser, and adds a streaming file handle with its own 1300-line suite, so the shell's testable surface and the fixtures to reach it both change under this plan. Start it from the merged tree, not from either branch.

## The question this started from, and its answer

*Can more of the iOS shell's behavior be covered by `make test`, so a change does not need the simulator to be trusted?* **Yes, for the part that decides, not for the part that draws.** The shell's decisions — what an open or an Add does, what a tap offers, what the card's state means for the tabs — are written inline in the view controllers and the two model classes, which only the simulator reaches. The drawing — layout, the safe area, animations, the tab accessory, the system picker — stays in the simulator, where the layout and frame probes built for #132 are the right tool.

Two of the four defects a review found in #132 were fixed with unit tests the same hour (`DropboxMirrorTests`: a cancel during a token refresh, a revoke with an expired token). The other two, and the strip bug the layout probe caught, had no test to land in. That gap is what this plan closes.

## Where the line is today

`VibeTests` is a macOS bundle that compiles its sources from the app tree (`project.yml`, the `VibeTests` list; `Tests/AGENTS.md`). From the iOS shell it already builds and tests:

| Runs on the Mac today | Tested by |
| --- | --- |
| `DropboxClient`, `DropboxMirror` | `DropboxMirrorTests`, over an `NSURLProtocol` stub and a temp root |
| `FileSearchIndex`, `FileSearchRules.h` | `FileSearchRulesTests` |
| `PageWaveformCoordinator` | its own suite |
| `PlayerScreenRules.h`, `DropboxRules.h` | `PlayerScreenRulesTests`, `DropboxRulesTests` |

Everything else under `Vibe/iOS/` is reached only through the debug channel and the touch driver. The view controllers hold no `static` logic at all: `BrowserViewController.m` (1400 lines), `RootViewController.m` (900) and `LibraryViewController.m` (750) make every decision inline, beside the UIKit call that acts on it. The three `*Rules.h` seams that exist are the search, the screen state and the Dropbox paths; none covers the shell's own rules.

## Three moves, in order of payoff

### 1. Compile `FolderSession` into the Mac test target

The biggest win. `FolderSession` owns the open and Add orchestration that `Vibe/iOS/AGENTS.md` spends its longest paragraphs and most `TRAP:`s on: `openIntentGeneration` and the Add token, the promotion of the first Add onto nothing and the waiters parked behind it, the empty-open carry of `_landedOpenIntentGeneration`, the base-is-the-first-contributor rule, the bounded restore and its merge order, recents, the settle event every Add ends in, and acquire-before-release on the scope set. Every one of those is a race or an ordering rule, invisible on local files where a resolve takes a millisecond and wide open on a cold provider — exactly what a test with held provider calls makes deterministic.

Its source is UIKit-free except for the header's `#import <UIKit/UIKit.h>` and one device-name lookup on main (the recents' display name). Its imports are `AppSettings`, `AppStats`, `AudioTrack`, `DropboxMirror`, `FavoritesStore`, `FileSearchRules.h`, `NSURLUtil` and `SearchFolderStoreInternal.h`; of these only `FavoritesStore` and `SearchFolderStore` are not in the target yet, and neither draws (`FavoritesStore.m` has no UIKit reference, `SearchFolderStore.m` one, to check). So the dependency pull is two stores, not the shell.

The shape is `DropboxMirrorTests`': a temp root for the folders, real listings on disk, and the two main-only stores either compiled in with a temp defaults suite or stubbed at their one query each (`grantCoveringURL:`, `resolvedRootCoveringURL:`). Security scopes cannot be exercised on the Mac — `startAccessingSecurityScopedResource` answers NO for a plain file URL, which the session already treats as "not failure" — but the bookkeeping around them can: which URLs are held, that a replace installs the successor set before stopping the previous one, that an append extends rather than replaces.

The tests to write first are the ones the doc's `TRAP:`s describe, since each is a bug that shipped once:

- Two Adds onto an empty playlist: the first promotes, the second parks and appends after the landing, and neither cancels the other.
- An Add tapped during an open that never lands is dropped; one tapped alongside a promotion is not.
- An open that finds nothing carries the landed generation forward, and a later Add still lands.
- A restore of `[file, folder]` keeps the file as the base.
- A folder in the Dropbox mirror nothing has listed yet is listed before the open reads it, and one already listed is not listed again.
- Every Add ends in exactly one `didAppendTracks:`, empty when it landed nothing.

### 2. Extract the view controllers' decisions into `*Rules.h` seams

The repository's own mechanism for "rendering is the whole class" (`Tests/AGENTS.md`): a header-only seam the shipping class **calls**, tested from the Mac. A new seam is a new file, so under the complexity budget each is a request argued on its own terms; the argument for each below is a bug that would have been a one-line test.

- **The browser's row actions.** What a tap and a long press offer per row kind — file, folder, Dropbox placeholder, CUE sheet — in the picker and in the Add sheet; the replace-confirm rule (`+confirmReplacingPlaylistOf:…`: ask only when the playlist was built by hand); Select mode's glyphs; the filter field's threshold; the subfolder walk's caps. All of C1 through C8 in `ios-dropbox-ui-feedback.md` were changes to these rules, verified by tapping.
- **The card fold in `RootViewController`.** `expanded`, `cardAnimating` and `interactiveDrag` resolve to: tabs hidden, snapshot present, strip wanted, and whether lifted rows settle. The strip bug of 2026-10-02 (the accessory removed on expand clamped a bottom-scrolled playlist by its height) was a wrong answer from this fold; `updateBackdropVisibility`, `refreshMiniPlayer` and `syncTabSurfaces` each restate a part of it today.
- **The library's follow rule.** A track change scrolls to the playing row, or defers it while hidden, except under shuffle. Three inputs, one answer.
- **The pager's waveform gate.** Ask for a waveform unless the file is a provider's dataless file; a Dropbox placeholder is asked (the cache answers from its stat). Two inputs; a review finding in #132.

Each seam also retires a sentence of prose from `Vibe/iOS/AGENTS.md`, since the test states the rule.

### 3. `PlaybackController`, by seams rather than whole

It is the model, but it pulls the real `AudioPlayer`, `AppSettings`, both stores, `DropboxMirror` and `WidgetPublisher`. Running it as itself on the Mac means replacing the player, which is more machinery than the decisions are worth. The path that fits is the one `PlaybackDeliveryRules.h` already took for the track-end rule (`VibePlaybackShouldAdvanceAtTrackEnd`, shared with the mac): move its pure decisions into seams as they are touched — the Add settle, the metadata neighborhood, the empty-folder bring-forward, which open URL context wins — and leave the player wiring to `make test-audio` and the channel.

## What stays in the simulator, on purpose

Layout and the safe area, animations and their frame rate, `UITabAccessory`'s fixed height, the system document picker and the grants it mints, accessibility focus. `check-layout-stability.sh`, `sample_frame_rate` and `check_consistency` are the oracles for those (`vibe-debug`), and the Recents scope fix from the #132 review can only be checked on a phone, since the simulator cannot make a one-off picker grant.

## Order of work, once #134 is in

1. `FolderSession` into `VibeTests` with the six tests above; this is where the dependency pull is learned, so report it before moving anything.
2. The card fold seam, since it is the smallest and the most recently wrong.
3. The browser's row-action seam, against the decision list in `ios-dropbox-ui-feedback.md`.
4. The library follow rule and the waveform gate, as their files are next touched.
5. The follow-up noted in #132: the tests' `DropboxStubProtocol` and the debug channel's `VibeFakeDropbox` stand on the same two `DropboxClientInternal.h` methods; once #134's rewrite of `DropboxMirrorTests` is in, decide whether one can serve both. They differ on purpose today — the tests script inconsistencies a fixture directory cannot express.

Each step reports its net lines, new files and what it deleted, as every feature does.

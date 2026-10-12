# Future: unit tests for the iOS app shell

**Status: Not built.**

## The question, and the answer

*Can `make test` cover more of the iOS shell, so a change does not need the simulator to be trusted?* Yes, for the part that decides, not for the part that draws. The shell's decisions are written inline in the view controllers and the two model classes, which only the simulator reaches. These are what an open or an Add does, what a tap offers, and what the card's state means for the tabs. Layout, the safe area, animations, the tab accessory and the system picker stay in the simulator.

## Where the line is today

`VibeTests` is a macOS bundle that compiles sources from the app tree (`project.yml`'s `VibeTests` list, `Tests/AGENTS.md`). From the iOS shell it already tests:

| Runs on the Mac today | Tested by |
| --- | --- |
| `DropboxClient`, `DropboxMirror` | `DropboxMirrorTests`, over an `NSURLProtocol` stub and a temp root |
| `FileSearchIndex`, `FileSearchRules.h` | `FileSearchRulesTests` |
| `PageWaveformCoordinator` | `PageWaveformCoordinatorTests` |
| `PlayerScreenRules.h`, `DropboxRules.h` | `PlayerScreenRulesTests`, `DropboxRulesTests` |

The rest of the shell is reached only through the debug channel and the touch driver. Most decisions in `BrowserViewController`, `RootViewController` and `LibraryViewController` sit beside the UIKit calls that act on them.

## Three moves, in order of payoff

### 1. Compile `FolderSession` into the Mac test target

The biggest win. `FolderSession` owns the open and Add orchestration that `Vibe/iOS/AGENTS.md` spends its longest paragraphs and most `TRAP:`s on:
- `_openIntentGeneration` and the Add token.
- The first Add onto nothing promoting to an open, and the waiters parked behind it.
- The empty open carrying `_landedOpenIntentGeneration` forward.
- The base being the first contributor.
- The bounded restore and its merge order, and recents.
- The settle event every Add ends in.
- Acquire-before-release on the scope set.

Each is a race or an ordering rule. On local files a resolve takes a millisecond and hides it. On a cold provider it is wide open. A test with held provider calls makes it deterministic.

Its header imports UIKit, but its implementation does not draw. Its dependencies include `AppSettings`, `AppStats`, `AudioTrack`, `DropboxMirror`, `FavoritesStore`, `FileSearchRules.h`, `NSURLUtil`, `PlaylistFile` and `SearchFolderStoreInternal.h`. The two stores are not in the target. `FavoritesStore` has no UIKit reference. `SearchFolderStore` uses `UIDevice` for a display name, which needs a platform boundary or a test seam first.

Follow `DropboxMirrorTests`' shape: a temp root for the folders and real listings on disk. Compile the two main-only stores in with a temp defaults suite, or stub them at their queries (`grantCoveringURL:`, `resolvedRootCoveringURL:`). A plain temp file URL does not exercise a picker grant, because `startAccessingSecurityScopedResource` answers NO, which the session treats as "not failure". The bookkeeping can still be tested: which URLs are held, that a replace installs the new set before stopping the old one, and that an append extends the set.

Write first the tests for the doc's `TRAP:`s:

- Two Adds onto an empty playlist. The first promotes, the second parks and appends after the landing, and neither cancels the other.
- An Add tapped during an open that never lands is dropped. One tapped alongside a promotion is not.
- An open that finds nothing carries the landed generation forward, and a later Add still lands.
- A restore of `[file, folder]` keeps the file as the base.
- A folder in the Dropbox mirror that nothing has listed is listed before the open reads it. One already listed is not listed again.
- Every Add ends in exactly one `didAppendTracks:`, empty when it landed nothing.

### 2. Move the view controllers' decisions into `*Rules.h` seams

A header-only seam that the shipping class calls, tested from the Mac (`Tests/AGENTS.md`). Each seam is a new file, so each is a request argued on its own terms.

- **The browser's row actions.** What a tap and a long press offer per row kind (file, folder, Dropbox placeholder, CUE sheet, M3U), in the browser and the Add sheet. The replace-confirm rule (`PlaybackController`'s `confirmReplacingPlaylistFrom:…` asks only when the playlist was built by hand). Select mode's glyphs, the filter field's threshold and the subfolder walk's caps.
- **The card fold in `RootViewController`.** `expanded`, `cardAnimating` and `interactiveDrag` resolve to: tabs hidden, snapshot present, strip wanted, and whether lifted rows settle. `updateBackdropVisibility`, `refreshMiniPlayer` and `syncTabSurfaces` each restate part of it today. A wrong answer here once clamped a bottom-scrolled playlist by the accessory's height on expand.
- **The library's follow rule.** A track change scrolls to the playing row, or defers it while hidden, except under shuffle.
- **The pager's waveform gate** (`WaveformWaitsForOpen` in `PlayerViewController+Pager.m`). Ask for a waveform unless the file is a provider's dataless file. A Dropbox placeholder is asked, since the cache answers from its stat.

Each seam also retires a sentence from `Vibe/iOS/AGENTS.md`, since the test states the rule.

#### Browser regression cases

Host-less tests must call the shipping decisions. Drawing and navigation stay in the simulator. Open product questions are the [browser follow-ups](ios-icloud-improvements.md#browser-follow-ups).

| Case | Expected behavior |
| --- | --- |
| File and folder actions | An audio-file tap plays that file alone. A folder tap browses it, in Files, Recents and Search. Play in Folder is a separate long-press action. Cover local files, remote placeholders, and CUE and M3U expansion. |
| Add sheet | Taps append and dismiss. The root title and each pushed level's prompt name Add to Playlist. |
| Replacing a playlist | Ask only after an Add has landed, restored additions included. Cover Replace, Add Instead and Cancel. A playlist with no additions replaces directly. |
| Folder commands | Ordinary Play never recurses. Play and Add with Subfolders respect the caps and report an early stop. A folder with no direct songs offers the subfolder menu. An empty result still settles an Add exactly once. |
| Sort | The browser writes the shared folder-open sort setting. It keeps no per-folder order. |
| Search state | Scope order is All, Playlist, Local, Dropbox. Appearing with an empty query resets to All. No Results waits for every scoped source. A Dropbox error stays distinct from no matches. |
| Folder navigation | Open Folder highlights the originating file after listing. A folder search hit browses. A failed resolve shows an error. |
| Connect flow | Signing in from the Files Connect row opens the account root. Cancelling sign-in is quiet. |
| Display names | Browser, playlist and favorites share the folder-name rule, the Dropbox account root included. New Recents records keep their display name. |
| Selection and filtering | A row swipe never enters Select mode. Select offers Select All and a count. The filter appears at the row threshold and does not change visibility on scroll. |

### 3. `PlaybackController`, by seams

It pulls in the real `AudioPlayer`, `AppSettings`, both stores, `DropboxMirror` and `WidgetPublisher`. Running it whole on the Mac means replacing the player, which costs more than the decisions are worth. Follow `PlaybackDeliveryRules.h` (`VibePlaybackPreviousIsAvailable`, shared with the mac). Move pure decisions into seams as they are touched: the Add settle, the metadata neighborhood, the empty-folder bring-forward, and which open URL context wins. Leave the player wiring to `make test-audio` and the channel.

## What stays in the simulator

Layout and the safe area, animations and their frame rate, the fixed height of `UITabAccessory`, the system document picker and its grants, and accessibility focus. The oracles are `check-layout-stability.sh`, `sample_frame_rate` and `check_consistency` (`vibe-debug`). A one-off picker grant can only be checked on a phone.

## Order of work

1. `FolderSession` into `VibeTests` with the six tests above. Report the dependency pull before moving anything.
2. The card fold seam, the smallest.
3. The browser's row-action seam, against the regression cases.
4. The library follow rule and the waveform gate, as their files are next touched.
5. Decide whether the tests' `DropboxStubProtocol` and the debug channel's `VibeFakeDropbox` can share one fixture. Both stand on the same two `DropboxClientInternal.h` methods. They differ on purpose today: the tests script inconsistencies a fixture directory cannot express.

# Row loading indicator

## Context

A cloud file can take seconds — sometimes minutes — to come down from its file provider before Vibe can open it. Today the only place that shows is the **waveform**: `WaveformLoadingIndicator` puts up a shimmering midline, and switches to a determinate fill when `DownloadProgressMonitor` reports a fraction. The playlist and library rows show nothing at all, so a user watching a list of cloud tracks has no idea which file is on the wire.

The fix is a **small loading bar in the row's number gutter** — the same 16pt slot the `EqualizerIndicatorView` occupies on the playing row, on both platforms. It is the same control the waveform already draws, extracted and given a second size: a single horizontal pill at one EQ bar's weight, spanning the gutter width.

Two things make this cheap and honest:

- **It is one control across two sizes and both modes.** The waveform indicator is already "a track, a filled head over `[0, fraction]`, and a shimmer sweeping only the unfilled remainder", with indeterminate being simply the case where nothing is filled. Row mode changes metrics, not structure.
- **A row shows it only while a provider transfer is really running for its file.** Not "is a cloud file", not "is queued" — running. `AudioFileMaterializationCoordinator` already bounds concurrent transfers to `maximumInteractiveMaterializations` (2) + `maximumBackgroundMaterializations` (1), so dropping a 5,000-file cloud folder lights up **at most three rows**, and every other row keeps its plain number.

---

## A. The shared control

### A1. Extract `WaveformLoadingIndicator` → `Vibe/Controls/LoadingIndicator.{h,m}`

Move `Vibe/WaveformUI/WaveformLoadingIndicator.{h,m}` to `Vibe/Controls/`, renaming the class to `LoadingIndicator`. It already qualifies for `Controls/`: pure `CALayer` work, no view, no window, no trait collection, and now genuinely drawn by both apps in two places each. It imports only QuartzCore, so `Controls/CLAUDE.md`'s "neither side imports `Audio/`" holds.

Both directories are recursive shared source entries, so **no `project.yml` change is needed for the move** — but see D3 for the test target.

Add a style to the initializer:

```objc
typedef NS_ENUM(NSUInteger, VibeLoadingIndicatorStyle) {
    VibeLoadingIndicatorStyleWaveform = 0,  // the hairline midline, unchanged
    VibeLoadingIndicatorStyleRow,           // a single EQ-bar-weight pill
};

- (instancetype)initInLayer:(CALayer *)hostLayer
                      style:(VibeLoadingIndicatorStyle)style
                     isDark:(BOOL)isDark
              contentsScale:(CGFloat)contentsScale;
```

Everything else on the public surface — `layoutInBounds:`, `setProgress:inBounds:`, `endSweepKeepingFill`, `removeFromHost`, `updateColorsForDark:`, `updateContentsScale:` — stays exactly as it is. **The waveform style must stay pixel-identical**; all visual risk belongs to the new row style.

### A2. `Vibe/Controls/LoadingIndicatorMath.h` — the per-style metrics

Today's numbers are file-scope constants in `WaveformLoadingIndicator.m` (`kSweepDuration`, `kFrontFadePoints`) plus `WaveformUI/WaveformMidline.h` (`kVibeMidlineHeight`, `kVibeUnplayedWaveformAlpha`, `kVibeInertMidlineAlpha`, `kVibeLoadingFillAlpha`). Four of them are width-dependent or style-dependent and must become a function of `(style, width)`:

```objc
typedef struct {
    CGFloat height;
    CGFloat cornerRadius;
    CGFloat bandWidth;        // the sweeping shimmer's own width
    CGFloat frontFadePoints;  // the filled head's soft front
    CGFloat trackAlpha;
    CGFloat shimmerAlpha;
    CGFloat fillAlpha;
} VibeLoadingIndicatorMetrics;

static inline VibeLoadingIndicatorMetrics
VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyle style, CGFloat width);
```

`*Math.h` is the correct suffix under `make check-vocabulary` rule 3 — it returns numbers in the problem's units, and it is header-only with no `.m` beside it. It is also the one genuinely testable seam in this feature (D1).

**Waveform style** returns exactly today's values, so nothing moves:

| Field | Value |
| --- | --- |
| `height` | `1` (`kVibeMidlineHeight`) |
| `cornerRadius` | `0` |
| `bandWidth` | `MIN(MAX(width * 0.35, 40), …)` — today's expression |
| `frontFadePoints` | `14` |
| `trackAlpha` / `shimmerAlpha` / `fillAlpha` | `0.275` / `0.375` / `0.85` |

**Row style**, sized against the 16pt gutter and the EQ bars beside it:

| Field | Value | Why |
| --- | --- | --- |
| `height` | `2` | One EQ bar's width: `(16 − 4 × 1.5) / 5 = 2`, from `kBarGap` and `kBarCount` in `EqualizerIndicatorView.m`. |
| `cornerRadius` | `height / 2` | Pill ends, exactly as `layoutBars` gives each EQ bar. |
| `bandWidth` | `MAX(width * 0.35, 5)` | **See the trap below.** |
| `frontFadePoints` | `3` | 14pt is almost the whole 16pt control. |
| `trackAlpha` / `shimmerAlpha` / `fillAlpha` | `0.30` / `1.0` / `1.0` | The row mark reads at the EQ bars' weight, not the waveform's unplayed-bar weight. `kVibeUnplayedWaveformAlpha` exists to match arriving waveform bars, and there are none in a row. |

> **TRAP: the shimmer's 40pt minimum band width makes the row style hold still.** `bandWidth = MIN(MAX(width * 0.35, 40), MAX(remainder, 1))` clamps to the remainder on a 16pt control, so the band becomes the full width and the sweep animates a full-width block from `−8` to `24` — no visible motion, just a fade at the edges. The 40pt floor is a waveform number and must not survive into row metrics. A test asserts `bandWidth < width` for the row style (D1).

Delete `WaveformUI/WaveformMidline.h` and point its two macOS empty-state call sites at `LoadingIndicatorMath.h` instead — the empty line deliberately shares the loading track's weight and colour, and that must keep being true by construction rather than by a copied number.

### A3. `Vibe/Controls/LoadingIndicatorView.{h,m}` — the row's host view

`LoadingIndicator` needs a host layer, and a table cell needs a view. Add a thin shared view, structured exactly like `EqualizerIndicatorView` — one class, `#if TARGET_OS_OSX` only for the superclass, the layout hook, the appearance hook, and alpha:

```objc
@interface LoadingIndicatorView : NSView / UIView

// NO tears the control down entirely: no layers, no animation, nothing
// retained. Defaults to NO.
@property (nonatomic, getter=isActive) BOOL active;

// <0 is indeterminate — the shimmer owns the whole width. >=0 fills.
// A control that has never been given a fraction is indeterminate.
@property (nonatomic) float progress;

// Overrides the appearance-derived colour, as EqualizerIndicatorView.barColor
// does. The mac playlist forces white in the number gutter.
@property (nonatomic, strong, nullable) VibeColor *barColor;

@end
```

Behaviour:

- `active = YES` builds the `LoadingIndicator` in the view's own layer with `VibeLoadingIndicatorStyleRow` and lays it out; `active = NO` calls `removeFromHost` and drops it. **Never `endSweepKeepingFill`** — that exists for the waveform's "data landed while the download continues" case, which has no row equivalent.
- Layout (`layout` / `layoutSubviews`) forwards bounds to `layoutInBounds:`, and is a no-op on unchanged bounds, mirroring `layoutBars`.
- `progress` forwards to `setProgress:inBounds:`, which already eases to each sample over roughly the previous gap and never runs past what was reported. **Reuse that ease** — do not add a second one.
- Appearance change re-asserts `updateColorsForDark:`; a backing-scale change re-asserts `updateContentsScale:`.

**Lifecycle discipline.** This control is much cheaper than the equalizer and the reason should be written down where the next reader finds it: the sweep is one repeating `CABasicAnimation` on one layer. There is no display link, no timer, no app-side per-frame callback, and no path rebuild — the whole thing runs on the compositor. What it still must not do is hold a live animation for a row nobody can see, so **`active` must go NO on cell reuse, on hiding, and on detachment from a window**, and the row wiring in section C is responsible for that.

---

## B. Knowing which rows are actually transferring

### B1. The signal that already exists, and the one that does not

`AudioFileMaterializationCoordinator` is the single path-wide owner of the one operation that makes an audio file local — playback, prefetch, and both metadata roles all attach as role-bearing waiters to one standardized-path claim. It therefore already knows, exactly, which files are on the wire. It just does not tell anybody: the only introspection is `-stateSnapshotForTesting`, which returns counts and no paths.

The two edges are `-startClaim:` and `-finishClaim:runGeneration:ready:error:` in `AudioFileMaterializationCoordinator.m`, both on the serial `_stateQueue`.

**Gate the publication on `_datalessProbe(claim.url)`.** `startClaim:` runs for local files too — their run is a stat and a no-op coordinated read, which is precisely why `admitClaim:` exempts them from lane capacity. A local claim starts no transfer and must publish nothing, or a local playlist would flash indicators on every row. This is the same rule the internal header already states: *"Lane capacity, the admission grace, and the metadata hold all bound transfers, so a NO answer exempts a claim from every one of them."*

### B2. `Vibe/Audio/CloudTransferRegistry.{h,m}`

A new companion beside the coordinator. Main thread only, like `DownloadProgressMonitor` and the delegate paths it feeds.

```objc
@protocol CloudTransferRegistryObserver <NSObject>
// One coalesced callback per runloop turn, on main. The observer re-reads
// whatever rows it is showing; the registry names no rows and knows no UI.
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry;
@end

@interface CloudTransferRegistry : NSObject
+ (instancetype)sharedRegistry;

@property (nonatomic, weak, nullable) id<CloudTransferRegistryObserver> observer;

// YES only while a provider transfer is running for url's standardized path.
- (BOOL)isTransferringURL:(NSURL *)url;

// <0 when the transfer is running but no fraction is known yet — which is the
// indeterminate case, and on iOS against a third-party provider is the whole
// story. See DownloadProgressMonitor.h for why.
- (float)progressForURL:(NSURL *)url;

// The foreground open reports through the shell's OWN monitor, which is tied
// to the open-request identifier and also feeds the player's timeout
// extension. Routing that fraction in here stops the registry minting a second
// monitor — a second NSMetadataQuery and File Provider subscription — for a
// file already being watched.
- (void)noteProgress:(float)fraction forURL:(NSURL *)url;
@end
```

Keying is `VibeStandardizedAudioOpenPath(url)` from `Vibe/Audio/AudioFileOpenRules.h` — the same function the coordinator keys its claims by, so the two cannot disagree about what "the same file" means.

**Progress sourcing.** The registry mints one `DownloadProgressMonitor` per actively transferring path that is not already reporting through `noteProgress:forURL:`. `Vibe/Audio/` importing `Vibe/System/` is precedented — `AudioFileMaterializationCoordinator.m` already imports `CloudFileMaterializer.h`. Because lane capacity caps concurrent transfers at three, the fleet is at most three monitors and in practice one or two. Cancel each monitor on the matching finish; nothing may outlive its transfer.

Use `+monitorReplacing:forURL:currentURL:movement:handler:` with `currentURL` returning that path's own URL and `movement:` nil — the registry only paints, and the open's abandon deadline is fed by the shell's monitor and must not be extended from here.

**Observer count.** One weak observer, because each shell has exactly one row list (`PlaylistController` on macOS, `LibraryViewController` on iOS). A second observer means upgrading to counted registration; say so in the header rather than leaving it to be discovered.

### B3. Wiring the coordinator's edges

In `startClaim:`, after the dataless probe answers YES, `dispatch_async` to main a `beganTransferForPath:` on the shared registry. In `finishClaim:`, symmetrically, `endedTransferForPath:` — on **every** exit, including the `runWasCancelled` readmission path, which must end and then re-begin rather than silently stay begun. Declare the two on a `CloudTransferRegistry (Coordinator)` category or in `AudioFileMaterializationCoordinatorInternal.h`, so the publication surface is not public API.

Compute the probe once in `startClaim:` and stash it on the claim, so a run that starts and finishes cannot disagree about whether it was a transfer.

---

## C. The row wiring

The number gutter now has **three** states, in this precedence:

1. **Loading** — `registry.isTransferringURL:track.url`. Loading bar visible, EQ bars hidden, number hidden.
2. **Playing** — the current row, not transferring. EQ bars, as today.
3. **Neither** — the row number, as today.

Loading outranks playing deliberately: while the current track's open is in flight there is no output audio, so the equalizer is a row of collapsed dots. The loading bar says more.

### C1. macOS — `Vibe/Playlist/Mac/`

- `PlaylistTableView.makeCellViewWithIdentifier:` — add a `LoadingIndicatorView` to the `kPlaylistColumnNumber` prototype beside the existing `EqualizerIndicatorView`: same `kEqualizerWidth` (16) and X position, height `2`, vertically centred, `barColor = NSColor.whiteColor` to match `eqView.barColor` in the same gutter. Add `+loadingViewInCell:`, twin of `+equalizerViewInCell:`.
- `PlaylistController.tableView:viewForTableColumn:row:` — apply the three-state precedence above for the number column. Set `loadingView.active` and `.progress` unconditionally on every configure, the way `eqView.levelSource` is already set unconditionally, so a reused cell cannot carry a previous row's state.
- Adopt `CloudTransferRegistryObserver`. On change, walk `[tableView rowsInRect:tableView.visibleRect]` and reconfigure each number cell in place via `viewAtColumn:row:makeIfNecessary:NO`. **Do not `reloadData` and do not reload rows** — that would rebuild the playing row's `EqualizerIndicatorView` and disturb its demand balancing and selection.

### C2. iOS — `Vibe/iOS/LibraryViewController.m`

- `LibraryTrackCell.build` — add a `LoadingIndicatorView` constrained to `_numberLabel.centerXAnchor` / `content.centerYAnchor`, width `16`, height `2`, matching the indicator's existing constraints. Expose `loading` and `loadingProgress` cell properties that forward, exactly as `equalizerAudioOutputActive` forwards today.
- `prepareForReuse` must clear it, beside the two lines already there.
- `tableView:cellForRowAtIndexPath:` and the existing `syncEqualizerActivityForCell:` neighbourhood apply the three-state precedence.
- Adopt `CloudTransferRegistryObserver`; on change walk `tableView.visibleCells` and re-sync each. Same rule: reconfigure in place, never reload.

### C3. Feeding the foreground open's fraction back

In both shells' existing `didBeginLoading:` monitor handler — `MainPlayerController+PlayerEvents.m:76` and `PlaybackController+PlayerEvents.m:69` — add one line beside the existing waveform call:

```objc
handler:^(float fraction) {
    [weakSelf.trackDisplay setWaveformLoadingProgress:fraction];
    [CloudTransferRegistry.sharedRegistry noteProgress:fraction forURL:track.url];
}
```

**Leave everything else in those blocks alone.** The `movement:` callback feeds `noteOpenProgressForOpenRequestIdentifier:`, which is the player's open-timeout extension and is matched by open-request identity — it is not this feature's business, and the comment above it explains why the monitor is constructed there and nowhere else.

---

## D. Tests and checks

**D1. `Tests/LoadingIndicatorMathTests.m`** — the one real seam:
- Waveform style returns today's exact constants at several widths (a regression fence around "pixel-identical").
- Row style's `bandWidth < width` at 16pt — the 40pt-floor trap.
- Row style's `frontFadePoints < width`.
- `height` and `cornerRadius` give a pill: `cornerRadius == height / 2`.

**D2. `Tests/CloudTransferRegistryTests.m`** — the registry is Foundation-only if its monitor construction is injected. Follow `AudioFileMaterializationCoordinatorInternal.h`'s pattern: a `CloudTransferRegistryInternal.h` with a designated initializer taking a monitor-factory block, defaulted to the real one in `-init`. Then test begin/end pairing, the standardized-path keying, `noteProgress:` suppressing the factory for that path, a cancelled-and-readmitted run ending and re-beginning, and no monitor surviving its transfer.

**D3. `project.yml`** — add the new headers and `CloudTransferRegistry.m` to the `VibeTests` source list, then `xcodegen generate`. The `Vibe`/`VibeiOS` targets need no change: `Vibe/Controls` and `Vibe/Audio` are already recursive shared entries, which is also why the new files join the iOS target automatically and must stay AppKit-free outside their `TARGET_OS_OSX` guards.

**D4.** `make check-layout`, `make check-vocabulary` (rule 3 is why the metrics file is `*Math.h`), `make analyze CONFIG=Release`, and `make build-ios`.

**D5. Localization** — none. This control draws no text, so `VibeStrings.h` and the catalogs are untouched.

---

## E. Verification

The debug channel already has everything needed except a readback.

**E1. Add a shared debug verb `dump_row_loading`** in `Vibe/Debug/DebugCommonVerbs.m` (a common verb, so `debug-ios.sh` gets it free), reporting both halves so a mismatch is visible:

```
{ transfers: [{path, progress}],
  rows: [{index, path, loading, progress, equalizer}] }
```

**E2. The real end-to-end run**, per the `vibe-debug` skill:

```bash
"$V" --debug-cmd set_fake_cloud 6 100 capacity=1 progress=linear
"$V" --debug-cmd open ~/…/test_audio_files
"$V" --debug-cmd play_index 0
"$V" --debug-cmd dump_row_loading
"$V" --debug-cmd dump_screenshot -   > /tmp/row-loading.png
"$V" --debug-cmd set_fake_cloud 0
```

The assertions that matter:

- **At most three rows** report `loading: true` at any sample, and every one of them appears in `transfers`. This is the whole point of the feature — check it against a corpus far larger than three.
- A row with `loading: true` starts at `progress: -1` and later reports a fraction — indeterminate first, determinate when the provider speaks. `progress=stall` in `set_fake_cloud` parks one partway, which must leave the fill parked rather than creeping.
- With `set_fake_cloud 0` (everything local), **no row ever shows it**, including during a burst of skips. This is the local-exemption path in B1.
- `dump_cloud_health` reports zero claims and zero waiters after a settle, and `dump_row_loading` reports zero transfers at the same moment. A leftover indicator with no transfer behind it means B3 missed an exit.

**E3.** `.claude/skills/vibe-stress`'s cloud scenario suite (`cloud-scenarios.py`) is the natural home for a scenario asserting the bounded-rows property under a churning provider.

**E4.** Screenshot both platforms in light and dark, playing and loading, to confirm the row bar reads at the EQ bars' weight and the waveform indicator is unchanged.

---

## F. Documentation

The repo's convention is that each directory documents its own half and the root owns the coupling.

- **`Vibe/Controls/CLAUDE.md`** — `LoadingIndicator` and `LoadingIndicatorView`: one control, two styles, two modes; the compositor-only sweep; the `active` teardown rule; the 40pt band-width trap.
- **`Vibe/WaveformUI/CLAUDE.md`** — the indicator moved to `Controls/`; keep the `endSweepKeepingFill`, shimmer-clip, and sweep-phase traps where they are, since they are still the waveform's to know.
- **`Vibe/Audio/CLAUDE.md`** — `CloudTransferRegistry` as the coordinator's publication surface, and the dataless gate.
- **`Vibe/Playlist/Mac/CLAUDE.md`** and **`Vibe/iOS/CLAUDE.md`** — the three-state number gutter and its precedence.
- **Root `CLAUDE.md`, Cross-directory guarantees** — the new one:

  > **A row shows the loading bar only while a provider transfer is actually running for its file.** `AudioFileMaterializationCoordinator` publishes its `startClaim:`/`finishClaim:` edges to `CloudTransferRegistry` gated on the dataless probe, so a local file — whose run is a stat and a no-op coordinated read — publishes nothing, and a claim merely queued behind lane capacity publishes nothing either. Lane capacity therefore bounds the indicators as well as the transfers: dropping a large cloud folder marks the one to three files on the wire and leaves every other row its number. The playing row's fraction comes from the shell's own open-request-identified monitor via `noteProgress:forURL:`, so no file is watched by two monitors.

- **`.claude/skills/vibe-debug/SKILL.md`** — `dump_row_loading` beside `set_loading`.

---

## G. Files

**New**
- `Vibe/Controls/LoadingIndicatorMath.h`
- `Vibe/Controls/LoadingIndicatorView.{h,m}`
- `Vibe/Audio/CloudTransferRegistry.{h,m}`, `CloudTransferRegistryInternal.h`
- `Tests/LoadingIndicatorMathTests.m`, `Tests/CloudTransferRegistryTests.m`

**Moved / removed**
- `Vibe/WaveformUI/WaveformLoadingIndicator.{h,m}` → `Vibe/Controls/LoadingIndicator.{h,m}`
- `Vibe/WaveformUI/WaveformMidline.h` → folded into `LoadingIndicatorMath.h`

**Modified**
- `Vibe/Audio/AudioFileMaterializationCoordinator.m`, `…Internal.h`
- `Vibe/Playlist/Mac/PlaylistTableView.{h,m}`, `PlaylistController.m`
- `Vibe/iOS/LibraryViewController.m`
- `Vibe/Mac/MainWindow/MainPlayerController+PlayerEvents.m`, `Vibe/iOS/PlaybackController+PlayerEvents.m`
- `Vibe/WaveformUI/Mac/AudioWaveformView+Loading.mm` and the iOS scrubber — import rename only
- `Vibe/Debug/DebugCommonVerbs.m`
- `project.yml` (`VibeTests` sources only)

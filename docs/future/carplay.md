# Future: CarPlay

Written 2026-08-16, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against branch `ios-app` at `d457ad3` **with its uncommitted working tree**. Re-check every anchor before acting.

## The question this started from, and its answer

*Can the waveform scrubber come to CarPlay?* **No** — and it is a platform no, not a hard problem. The rest of the app can go, and should; the waveform stays on the phone.

A CarPlay app does not render. It hands the system a stack of templates — `CPTabBarTemplate`, `CPListTemplate`, `CPSearchTemplate`, `CPNowPlayingTemplate`, `CPAlertTemplate`, `CPActionSheetTemplate` — and the head unit draws them, in the car maker's styling, on the far side of the CarPlay link. There is no view, no layer, no drawing surface, and **no touch delivery**: the app receives *selection* callbacks from templates, never gestures. The one framework with a real rendering surface, `CPMapTemplate`, belongs to the navigation, EV-charging, parking and food-ordering entitlements; an audio app cannot get it, and Apple will not grant one to a music player. That is the point of the template model — driver-distraction limits are enforced by making custom UI unexpressible.

So the scrubber has no surface to live on, and even a static picture of one has no way to receive a drag.

**Three dead ends, so they are not re-explored:**

- **Waveform rendered into `MPMediaItemArtwork`.** The artwork is a request-handler returning a `UIImage`, so it *can* hold a waveform. It is still non-interactive (no touch reaches it), pull-based and cached rather than a frame surface, shared with the lock screen and Control Center — republishing it on a timer rewrites the artwork everywhere on the phone too — and animated custom content in the now-playing slot is what CarPlay entitlement review exists to reject.
- **`CPNowPlayingButton` glyphs.** Up to five, small, and a button image is not a canvas.
- **A waveform thumbnail as the `CPListItem` image.** This one is actually legal — a small, static, per-track picture. It is also not scrubbing, and at list-row size a waveform reads as noise. Mentioned only because it is the sole place waveform pixels could legitimately appear in a car.

## The seek story, which is the real value add

`CPNowPlayingTemplate`'s progress display is system-drawn, and **whether it offers a draggable scrubber at all is up to the head unit**. On the author's own car it does not: there is no way to seek within a track in CarPlay's Now Playing screen, so `changePlaybackPositionCommand` — which the app already implements (`NowPlayingController.m:204`) — is simply unreachable there.

That makes `skipForwardCommand` / `skipBackwardCommand` the only in-car seek on such a unit, and therefore the one genuinely new *capability* on this whole list rather than a nicety. Both are currently in the disabled set (`NowPlayingController.m:219`), correctly, because the app models neither.

Notes for whoever implements them:

- **They are seconds, not bars.** `MPSkipIntervalCommand.preferredIntervals` is a list of second counts, and the head unit draws the chosen number on the glyph. The mac's bar-based skip cannot be expressed through it, and a "±1 bar" that renders as "±7" is worse than 15/30.
- **TRAP to verify before shipping: enabling them changes the phone.** `MPRemoteCommandCenter` is process-global — the same registration feeds CarPlay, the lock screen, Control Center, AirPods and the mac's media keys. The system has historically chosen between next/previous-track and skip-interval buttons in the compact transport when both are enabled, podcast-style. If enabling skip costs the lock screen its next/previous buttons, that is a bad trade for a phone-first music player and the commands may have to be enabled *only while a CarPlay scene is connected*. Check this on a real device before deciding; it is the one thing that could make this change not worth making.
- Everything else the car needs is already live. `NowPlayingController` publishes title, artist, artwork, duration and rate, and routes play, pause, toggle, next and previous back to the same transport entry points the on-screen controls use (`PlaybackController+NowPlaying.m:40-68`).

## What already works today, with no code at all

Plugging the phone into a CarPlay head unit already routes Vibe's audio, shows the track, artwork and elapsed time on the car's own now-playing screen, and gives play/pause, next, previous and steering-wheel controls — because the app is the system's active Now Playing app. What the entitlement buys on top is a **Vibe icon on the CarPlay home screen** and the ability to choose a track without picking up the phone. That is the whole deliverable; it is worth being clear-eyed that the audio already plays fine.

## What building it actually involves

### 1. The entitlement, which is a gate

`com.apple.developer.carplay-audio`, requested from Apple through the CarPlay request form and granted per App ID. Manual, free, and slow. VibeiOS has **no entitlements file at all** today — only the mac target has one (`project.yml:291`) — so this means a new `Vibe/iOS/VibeiOS.entitlements` plus `CODE_SIGN_ENTITLEMENTS` in the iOS target's `settings.base`, which currently signs with `CODE_SIGN_STYLE: Automatic` and an empty `PROVISIONING_PROFILE_SPECIFIER` (`project.yml:456,458`).

Simulator testing with the entitlement key present but not yet granted is *reported* to work (Simulator ▸ I/O ▸ External Displays ▸ CarPlay); a device build needs the real grant. Verify before planning a schedule around it.

### 2. A second scene, which collides with a documented decision

CarPlay is a `CPTemplateApplicationSceneSessionRoleApplication` scene, live *alongside* the window scene. Today the app is deliberately single-scene, and `project.yml`'s manifest says why: `UIApplicationSupportsMultipleScenes: false`, commented "a second scene would spawn a second engine" — because `VibeiOSSceneDelegate` owns the one `PlaybackController` (`VibeiOSSceneDelegate.m:14,28`), and that comment is already stale in naming `PlayerViewController` as the owner.

CarPlay does not want a second engine; it wants a second *view* of the one that exists. The change is therefore:

- **Hoist `PlaybackController` ownership to `VibeiOSAppDelegate`**, which today owns nothing but launch logging (`VibeiOSAppDelegate.m:14-23`). Both scene delegates then borrow the one instance.
- **Restate the guarantee as "one window scene", not "one scene"**, in `project.yml`'s manifest comment and in `Vibe/iOS/CLAUDE.md`'s "Multi-scene stays off, deliberately" paragraph. Whether the flag must literally flip to `true` for a template scene to coexist with the window scene needs checking against the current docs; the ownership move is required either way.
- **The fan-out is already the right shape.** `PlaybackController` broadcasts to a weak `NSHashTable` of `PlaybackObserver`s on main (`PlaybackController.m:31,37,84`) precisely because three views describe the same playback at once. The CarPlay list and now-playing templates become a fourth observer and need no new plumbing.

**`Vibe/iOS/Info.plist` is generated by XcodeGen and gitignored** (`.gitignore:32`) — every plist change above goes in `project.yml`'s `info.properties` block, never in the file.

### 3. The library problem, which is the interesting one

Vibe's model is *the picked folder is the playlist*, and the pick comes from the system document picker or `UIDocumentBrowserViewController`. **Neither exists in CarPlay, and no template browses Files.** In the car the app can only offer what it already holds: the single restored bookmark (`kFolderBookmarkKey`, `FolderSession.m:13`).

A one-folder CarPlay app is close to useless, so making this worth shipping means `FolderSession` growing a **recent-folders list of bookmarks** rather than the one it keeps now — which is a good iPhone feature independently, and is the real prerequisite. Bookmark resolution is already off-main on the session's serial queue, so a list of them costs nothing new architecturally.

Templates then fall out easily: a `CPListTemplate` of recent folders, a `CPListTemplate` of the open folder's tracks (`isPlaying` on the current row, which is the template vocabulary's version of `EqualizerIndicatorView`), `CPSearchTemplate` over the same match that `SearchViewController` uses, and `CPNowPlayingTemplate`.

### 4. Cloud folders degrade silently, and that is accepted

A dataless Dropbox or iCloud track takes seconds to make a sound, and in the car there is no shimmer, no determinate fill and no download progress to show — `DownloadProgressMonitor` has no consumer-side fraction on iOS anyway (`System/CLAUDE.md`). A list-item spinner is the entire available vocabulary. The deferred metadata sweep and the cache's cloud-lane hold still apply and still matter; they just have no visual explanation in the car.

## Files

- `project.yml` — iOS `info.properties` scene manifest, `CODE_SIGN_ENTITLEMENTS`, `CarPlay.framework` in `dependencies`, and the stale single-scene comment.
- `Vibe/iOS/VibeiOS.entitlements` — new.
- `Vibe/iOS/VibeiOSAppDelegate.{h,m}` — becomes the `PlaybackController` owner.
- `Vibe/iOS/VibeiOSSceneDelegate.m` — borrows it instead of creating it.
- `Vibe/iOS/CarPlay/` — new: the `CPTemplateApplicationSceneDelegate` and the template controllers, a `PlaybackObserver` between them. Under `Vibe/iOS/` rather than a shared subsystem, since CarPlay is iOS-only by construction.
- `Vibe/iOS/FolderSession.{h,m}` — the recent-folders bookmark list.
- `Vibe/System/NowPlayingController.m` — the skip commands, if the lock-screen trade above turns out acceptable.
- `Vibe/Common/VibeStrings.h` — every template title and list label is user-facing; `make strings` after.
- `Vibe/iOS/CLAUDE.md` — the multi-scene paragraph, and a CarPlay section.

## Open questions

1. Does enabling the skip-interval commands cost the lock screen and Control Center their next/previous buttons? Decides whether skip is unconditional or CarPlay-scoped.
2. Must `UIApplicationSupportsMultipleScenes` be `true` for a template scene beside the window scene?
3. Does the CarPlay simulator display honor the entitlement key before Apple grants it?
4. Is the recent-folders list worth building for the phone first, independently of any of this? It probably is, which would make CarPlay a follow-on rather than the reason.

# iOS app (VibeiOS target)

The iPhone app: a single-file player where **the current directory is the playlist**. The user picks a folder (or file) in the system document picker; the folder's audio files, filename-sorted, become the skippable playlist. Dropbox and iCloud work through their Files file-providers in the picker — no provider SDKs — and search is the picker's own. One screen: artwork, title/artist, the full-bleed waveform scrubber, and three buttons (playlist sheet, play/pause, next).

The target compiles the shared subset — `Vibe/Audio` minus the HAL device layer (`AudioDevice*`, `AudioPlayer+Devices`) and `Convert/`, `Vibe/Common` minus `AppStats`, the portable half of `Vibe/Util`, `Vibe/Waveform` minus `AudioWaveformView`, `Vibe/ThirdParty` — plus this directory. `project.yml` is the authority on the excludes; a new file in a shared directory lands in this target automatically, so it must be AppKit-free or `TARGET_OS_OSX`-guarded. CI's `build-ios` job enforces that on every push.

## The pieces

- **`PlayerViewController`** — the iOS `MainPlayerController`. Owns the engine, `Playlist`, both caches, `NowPlayingController`, the session and folder controllers, and the 3 Hz `UIUpdateTimer` (foreground-gated; the lock screen extrapolates from the last Now Playing publish). Every cross-directory invariant in the root CLAUDE.md applies unchanged: deliveries matched against the current track, auto-advance only from `didFinishPlaying:`, prefetch on every start, BPM/key via `AudioTrack.bpm`/`.key`.
- **`AudioSessionController`** — the AVAudioSession half of what `AudioPlayer+Devices` is on macOS. Playback category activated before every play (never at launch) and released with `NotifyOthersOnDeactivation` once playback sits idle past the engine's own idle stop, so an interrupted podcast gets its resume hint. Four events, four delegate verdicts, each mapped onto the player's public API: interruption Began/Ended pause and resume (was-playing is captured at the Began edge *only* — the config-change and route-loss pauses that pile up mid-interruption must not overwrite it); route loss (`OldDeviceUnavailable`) pauses; engine-config-change routes to `recoverFromEngineConfigurationChange`, which restarts the stopped engine in place so connecting AirPods or CarPlay keeps playing rather than pausing; media-services reset routes to `reinitializeAfterMediaServicesReset` (every audio object is dead per Apple's contract — the player rebuilds the engine and FX graph, and `PlayerViewController` re-parks the current track at the captured position). Nothing here touches the graph directly. A pause verdict during Loading parks the landing (`playPause` toggles `_pendingStartPaused` while Loading), so the engine never starts against an interrupted session.
- **`FolderSession`** — the picked location's owner: picker presentation, the security scope (held for the whole session — the player, TagLib, and the waveform loader read under it at arbitrary times; released only after a successor is in hand), the bookmark that restores the folder on relaunch (default `bookmarkData`; iOS has no `WithSecurityScope` option and doesn't need it), and the listing via `NSURLUtil audioFilesInDirectory:`. A single-file pick is a one-track playlist: iOS grants no sibling access from a file grant. A relaunch restore **parks** the remembered track — header, waveform, metadata loaded, nothing playing.
- **`WaveformScrubberView`** — the shared renderers on UIKit. The renderer tree hangs off a `geometryFlipped` sublayer, which gives the shared renderer math the y-up space the mac's layer-hosting NSView provides; do not "fix" coordinates in shared renderer code for iOS. Style is hard-wired to the app default (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`, Oversampling Detailed x4) until a style picker exists. Pan scrubs with the renderers' hover-highlight as finger feedback and seeks on release; tap seeks immediately; `isScrubbing` keeps the timer from fighting the finger.
- **`TrackListViewController`** — the playlist button's sheet: Choose Folder row + the directory's tracks, current row marked. Holds `Playlist` weakly; `PlayerViewController` forwards observer changes and metadata deliveries as row reloads.

Persistence lives in `FolderSession`'s own `NSUserDefaults` keys (`VibeiOSFolderBookmark`, `VibeiOSLastTrackFileName`), deliberately not in the shared `AppSettings`.

## Building and verifying

```bash
xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

**There is no debug command channel on iOS.** Verification is `simctl` plus the log stream plus looking:

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app
# The mac app's debug audio flags work verbatim — the engine code is shared:
# --no-audio-hw runs manual rendering (real-time pump, no output device),
# --silent zeroes the mixer. Default to both for test runs, like launch.sh
# does on macOS, so a test session never plays through the mac's speakers.
xcrun simctl launch booted com.commonwealthrecordings.Vibe --no-audio-hw --silent
xcrun simctl io booted screenshot shot.png
# Stream from the HOST: simulator processes log into the mac's unified log,
# and `log stream` inside the simulator (simctl spawn) is refused as
# non-admin. Info/debug are not persisted, so stream, don't `log show`.
/usr/bin/log stream --level debug \
    --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'
```

Feed it audio through the app's own container (`UIFileSharingEnabled` makes this the same folder "On My iPhone > Vibe" shows):

```bash
DATA=$(xcrun simctl get_app_container booted com.commonwealthrecordings.Vibe data)
mkdir -p "$DATA/Documents/Music" && cp Assets/test_audio_files/*.wav "$DATA/Documents/Music/"
# then pick Browse > On My iPhone > Vibe > Music in the app's picker, or:
xcrun simctl openurl booted "file://$DATA/Documents/Music/tone-long.wav"   # open-in-place path
```

Interruptions, route changes (headphone unplug), background audio past lock, and the lock-screen card need a real device — the simulator exercises none of them faithfully.

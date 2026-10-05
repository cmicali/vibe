# v1.15

* Added shuffle, repeat all, and repeat one
* Added CUE sheet (file and embedded) playback
* Added Ogg Opus, Ogg Vorbis (mac only), CAF, W64, M4B, M4R, and ADTS playback
* Added a crossfade slider, from off up to 3 seconds in tenths of a second, in place of the three fixed choices
* Added the 3-Band waveform style and Rekord Bin theme (mac only) that uses it
* Added a playhead line option for waveforms
* Improved FLAC decoding: seeking is now near-instant even for long files, less CPU and memory, and better compatibility
* Improved WAV and AIFF decoding: 1.4x–3.2x faster, better compatibility
* Improved playback performance: 20–30% less CPU and 15–25% less energy
* Improved scan performance: tags and artwork 2x faster, library scans use 20% less CPU
* Improved load performance: metadata cache at launch, large M3U playlists, and editing very large playlists
* Fixed crossfade doing nothing when one track plays into the next; it only worked when changing tracks by hand
* Fixed 24 and 32-bit little-endian AIFF-C files playing at the wrong length
* Fixed seeks in low-bitrate MPEG-2 MP3 files landing slightly off
* Fixed FLAC files that don't record their length showing no duration
* Fixed a crash when reading tags from certain malformed M4A and MP3 files
* Fixed release builds writing diagnostic logging
* mac: Added a Keyboard Shortcuts pane in Settings for full customization
* mac: Added Shuffle (⌥⌘S) and Repeat (⌘R) to the Playback menu, with their icons on the file-info line
* mac: Improved the Settings window: reorganized, with search
* mac: Improved Set as Default: it now also claims CUE and M3U files, and keeps going when one file type is declined
* mac: Fixed waveform bars rippling while the window is resized
* mac: Fixed single-key shortcuts on AZERTY, Greek, Cyrillic, and other non-US keyboard layouts
* mac: Fixed Convert to FLAC adding a click at every full-scale peak of a float file, and misreading 24 and 32-bit little-endian AIFF-C files
* mac: Fixed opening a CUE sheet or M3U playlist whose files are all missing doing nothing; Vibe now says it couldn't open them
* ios: Added Vibe's own file browser, alongside the system Files picker
* ios: Added Dropbox integration with audio streaming
* ios: Added opening CUE sheets and M3U playlists from the Files browser
* ios: Added shuffle and repeat buttons beside the transport controls, which can be hidden in Settings > Appearance
* ios: Added compact now-playing layouts for short iPad windows
* ios: Improved opening folders, which no longer stalls on slow cloud folders
* ios: Improved scrubbing and swiping between tracks while a waveform loads
* ios: Fixed pinch-zooming the waveform making playback jump back
* ios: Fixed swiping back to a track showing its old position before jumping to the start
* ios: Fixed the FX pad sometimes opening no bigger than its circle after a few track changes

# v1.14

* Added a rebuilt playback engine that plays every track straight to your audio device - faster, more stable, and better at handling devices coming and going
* Improved MP3 decoding and sample-rate conversion: higher quality, less CPU
* Improved: a normalized waveform no longer shrinks while it loads
* mac: Added optional volume control (Settings > Audio Output), themable
* mac: Added Lock Window Position, in the View menu and Settings > General
* mac: Added remembering the chosen output device when it's switched off or unplugged, and switching back to it, with its Bit-perfect and Exclusive settings, when it returns
* mac: Added keeping a USB audio interface's Bit-perfect and Exclusive settings when it's plugged into a different port
* mac: Changed: when another app takes exclusive use of the audio device, Vibe pauses and says so
* mac: Changed: losing the audio output mid-track now pauses instead of skipping ahead
* mac: Improved play, pause, and skip to no longer wait while an audio device switches or wakes up
* mac: Improved: a stuck network share no longer holds up other tracks, or the tags and artwork of cloud files
* mac: Improved quitting to be instant; Vibe restores the audio device in the background
* mac: Fixed starting a track or dragging the position freezing playback for a second or two
* mac: Fixed some MP3 files with extra data after their tags not playing
* mac: Fixed an audio device that was off when Vibe opened not being used when turned on
* mac: Fixed System Output stopping playback while macOS briefly had no default device
* mac: Fixed the last few milliseconds of a track being cut off at high sample rates
* mac: Fixed undoing a playlist reorder leaving a blank row
* mac: Fixed the Control Center placeholder art showing the wrong light or dark version
* ios: Added the FX pad: hold the circle on the now-playing screen and slide for low cut, reverb, and a tempo-synced delay
* ios: Added BPM detection, shown beside the format and key (Settings > Playback)
* ios: Added landscape layout
* ios: Changed the home-screen widget's waveform default to the Wiggle style
* ios: Changed: only the play button pauses; tapping the artwork no longer does
* ios: Improved scrolling, resampling, and relaunch speed with large libraries
* ios: Improved the output device button to respond anywhere on its pill
* ios: Fixed a playback error staying on screen after playback resumed
* ios: Fixed playback showing as playing after the system stopped the audio
* ios: Fixed a long reverb or delay tail being cut off when pausing

# v1.12

* mac: Added bit-perfect playback and exclusive mode for audio output devices
* mac: Added File > Save Playlist… (⌘S) to export the playlist as an M3U file
* mac: Added Settings > General > Load last playlist on launch
* mac: Added more theme customizations, including customizing transport controls, app icon, and more
* mac: Added Glassy theme, theme editor undo, and randomize buttons for theme settings and colors
* mac: Added Snake and Tangerine themes; dropped Signal Workshop and folded Technical Bars into Technical
* mac: Settings UI improved, including new audio device picker
* mac: Enabling audio effects no longer requires restarting the app
* ios: First public release
* ios: Improved playlist handling, including add to playlist
* ios: Added small and medium size widgets
* Added new waveform styles (Wiggle and Wiggle MC)
* Improved waveform normalize to only boost quiet tracks
* Improved performance of large folder loads and window resizing
* Fixed audio now unchanged when low-cut FX is disabled (was slightly colored before)
* Fixed Dock album art not updating after switching themes

# v1.11

* mac: Added theming and theme editor
* mac: Added playlist editing: multi-select, remove, drag/drop
* mac: Added accessibility/VoiceOver to waveform and pitch fader
* ios: New favorites tab
* ios: Updated now playing screen design, added output device picker
* Added new waveform styles
* Added waveform normalize and gain settings
* Added show traffic lights setting
* Added QTA file support (Voice Notes export format)
* Improved slow/cloud file loading
* Improved playlist scrolling performance with large libraries
* Fixed loading symlinked folders

# v1.10

* Added color themes and customizable colors for window and waveform
* Added album art load from song's folder if song has no tagged artwork
* Added more reliable cloud file loading w/ progress bar (iCloud Drive, Dropbox)
* Added new settings window with many more configuration options
* Added keyboard support in playlist w/ enter to play
* Added live EQ animation based on audio
* Added initial version of iOS app/UI that uses macOS codebase
* Added support for macOS 13 Ventura and later (previously required macOS 14)
* Improved resizing of waveforms, especially for non-detailed ones
* Improved performance of large library loads, metadata loading, and artwork loading
* Improved playhead animation smoothness for short files
* Improved consistency of translations/localization 
* Fixed memory leaks (dock icon artwork, player teardown, engine idle stop)
* Fixed file descriptor leak (AVAudioFile issue on unreadable or partially-downloaded audio files)

# v1.9

* Added gapless playback: with crossfade off, tracks auto-advance with no gap
* Added playlist file support: .cue and .m3u open as ordered track lists
* Added download progress display for cloud files (iCloud Drive, Dropbox)
* Added "Always on Top" and "Show File Info" settings
* Added Permissions settings pane; folder access now persists across launches
* Added support for macOS 14 Sonoma and later (previously required macOS 26)
* Improved waveform highlight smoothness on short files and samples
* Fixed non-square album art; now displays as a centered square crop
* Fixed opening files passed on the command line
* Fixed Convert to FLAC when the same file is in the playlist twice
* Fixed folder access sometimes not applying to files opened at launch

# v1.8

* Added settings window
* Added key tag display and optional key detection (default: off)
* Added Czech, Slovak, Hungarian, Greek, Vietnamese, Indonesian, and Thai localizations (now 30 languages)
* Fixed ⌘W not closing the Settings and About windows

# v1.7

* Localized into 23 languages
* Added convert to FLAC option for uncompressed files, with undo/redo and optional delete original
* Add copy file and copy name menu items

# v1.6

* UI Enhancements (FX icons, highlight on waveform seek, new empty states)
* UI Fixes (handling of long file names)
* Performance improvements

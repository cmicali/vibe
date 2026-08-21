# 1.10

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

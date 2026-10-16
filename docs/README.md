# Docs

Every file and directory in `docs/`, with what it holds. The rules for changing a piece of code live in the `AGENTS.md` beside it. [architecture.md](architecture.md) says which one to read.

## Pages

- [app-store-releasing.md](app-store-releasing.md): releasing to the App Store. It covers credentials, the localized product page, the metadata upload, and shipping a build.
- [architecture.md](architecture.md): a map of the code for contributors. It covers the tree, each subsystem, the path a file takes from open to sound, and where to look for what.
- [audio-quality.md](audio-quality.md): what Vibe does to your audio between the file and the output device, and the measurements behind each choice.
- [file-loading-spec.md](file-loading-spec.md): the required behavior of file loading and metadata, as numbered items that code and tests cite. It also holds the policy numbers.
- [localization.md](localization.md): adding a string, adding a language, and testing one.
- [performance.md](performance.md): every release benchmarked on one machine, with charts.
- [themes.md](themes.md): the user's guide to themes on the Mac.

## Directories

- [audio-quality/](audio-quality/): the charts and tables that `audio-quality.md` shows, and `response.json`, the resampler's frequency response curves. `scripts/docs/audio_quality.py` draws them and holds the other numbers.
- [bugs/](bugs/): `open-issues.md`, bugs seen in testing that are not fixed or not explained.
- [future/](future/): plans and studies for work that is not built, or only partly built. Each file opens with its status.
  - `agent-build-slots.md`: separate build slots for agents working at once.
  - `carplay.md`: CarPlay.
  - `cloud-services-order.md`: which cloud file services to handle next, in order.
  - `dropbox-shared-links.md`: browsing a shared Dropbox folder link on iOS.
  - `ios-google-drive.md`: Google Drive as a Files-tab source on iOS.
  - `ios-icloud-improvements.md`: follow-ups for iCloud Drive in the iOS browser.
  - `ios-shell-unit-tests.md`: unit tests for the iOS app shell.
  - `share-links.md`: short links that open a remote track in Vibe.
  - `source-format-output.md`: keeping the source's sample format through bit-perfect output.
  - `streaming-any-source.md`: streaming from any source.
  - `tempo-accuracy.md`: making tempo detection more accurate.
  - `unsandboxed-direct-build.md`: an unsandboxed build of the direct download.
  - `vm-stress-harness.md`: running the stress harness in a VM.
- [not-doing/](not-doing/): designs that were weighed and declined, kept so they are not proposed again.
  - `airplay-output-devices.md`: why AirPlay targets are not in the output device list.
  - `rejected-alternatives.md`: alternatives to the current design and why they are excluded.
- [performance/](performance/): the charts and the release table that `performance.md` shows, and `results.json`, the data behind them. `scripts/bench/report.py` draws them.

## Which doc is the authority

`file-loading-spec.md` and `Vibe/Loading/AGENTS.md` cover some of the same ground. Where they overlap, the spec is the authority for behavior and for its policy numbers. `Vibe/Loading/AGENTS.md` is the authority for how the code works.

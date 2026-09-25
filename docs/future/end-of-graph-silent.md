# Hardware stress: remaining measurements and coverage

Validated 2026-09-25 against PR66’s working copy. The end-of-render silence change and independent Now Playing suppression are implemented. The former mixer-node gate proposal and its engine-graph instructions are obsolete.

## Current behavior

- `VibeMasterBusRender` in [AudioPlayer+Pipeline.m](../../Vibe/Audio/AudioPlayer+Pipeline.m) runs the bus, optional varispeed/FX and meter, then zeroes the final buffers for `--silent`. The meter and beta signal capture see the real signal on both platforms. There is no additional silence node to attach or verify.
- [launch.sh](../../.claude/skills/vibe-debug/scripts/launch.sh) and [run-torture.sh](../../.claude/skills/vibe-stress/scripts/run-torture.sh) default to `--no-audio-hw --silent`. On macOS, `VIBE_AUDIBLE=silent` selects real HAL output with final-buffer silence; `VIBE_AUDIBLE=1` selects audible hardware playback. `stress.py` launches through `launch.sh`, so it inherits that selection.
- macOS test launchers add `--no-now-playing` unless `VIBE_NOW_PLAYING=1`. `NowPlayingController` also suppresses publication under `--no-audio-hw`. No new `VIBE_STRESS_HW` or `VIBE_NO_NOW_PLAYING` switch is needed.
- The automatic `VibeManualRenderPump` advances from elapsed time. Playback is not frozen, and the former AVAudioEngine manual-render startup measurements do not describe it. Its timer still cannot establish HAL start latency or hardware behavior.
- `dump_state.player.manualRendering` identifies the actual carrier; `audioPathSnapshot`/`dump_audio_path` reports the pipeline’s `silent` state. There is no `silenceGateActive` property. The iOS launcher treats any nonempty `VIBE_AUDIBLE` as an audible launch; macOS’s `silent` environment value must not be copied to it.

## Outstanding work

1. Measure whether silent HAL playback with media publication suppressed changes auto-switching AirPods or the system output. Test the explicitly selected output as well as System Output. Keep hardware an opt-in until the intended environment has evidence; use the existing device-selection path before proposing another launch flag. VM isolation is a separate option in [vm-stress-harness.md](vm-stress-harness.md).
2. Compare repeated seeded campaigns and shrinking under the automatic pump and real HAL. The seed reproduces generated operations, not asynchronous callback timing, under either carrier. Record journals, endings, failures and settled resource counters; retune waits only where measurements show a need.
3. Add demand-aware signal coverage to stress if useful. The current consistency oracle checks meter demand and output liveness, but does not prove publications advance with nonzero signal. Use a known non-silent fixture and the existing [equalizer counters](../../.claude/skills/vibe-debug/references/equalizer-counters.md); an occluded view, no demand or genuine silence must not fail the oracle. Respect the bounded beta probe’s independent meter hold.
4. Run longer HAL cloud/artwork and transport campaigns before making a harness-default decision. Retain deliberate pump coverage if defaults ever change; the completed 240-operation HAL torture run is bounded evidence, not a long soak.

Use the [debug](../../.claude/skills/vibe-debug/SKILL.md) and [stress](../../.claude/skills/vibe-stress/SKILL.md) workflows. Record selected device, actual carrier, silent state and media-publication mode with each result. Do not infer device isolation merely from zero output samples or suppressed Now Playing.

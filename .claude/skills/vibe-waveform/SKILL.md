---
name: vibe-waveform
description: Look at a real track's waveform the way the app draws it, without the app. The probe decodes a file with the production waveform loader and draws it with the production renderer, laid out as the iOS scrubber lays it out, at any time and zoom, in any style, palette and appearance. It writes a PNG, and prints Spectrum's sections, the mix and band levels behind each pixel, and the progressive deliveries of a streaming load. It builds at any git ref, so one command draws main and the working tree one above the other. Use when a waveform looks wrong in a screenshot (a kick's shape, a color edge, a jump while loading), before and after any change under Vibe/WaveformUI or vibe-libs' waveform/Waveform, to show a look change to the user, or to put pictures in a PR.
---

# Looking at a waveform

The probe is `VibeBenchComponents --waveform` (`Tests/BenchComponents/VibeBenchComponentsWaveformProbe.mm`). It is the component benchmarks' tool, so `perf.py` builds it at any ref (`vibe-perf`). `waveform.py` drives it. Prerequisites are those of `vibe-perf`: Xcode, `make setup` and `brew install ffmpeg`.

```bash
W=.claude/skills/vibe-waveform/scripts/waveform.py
$W draw "<file>" --at 29.5 --out build/waveform/now.png              # the working tree
$W draw "<file>" --ref main --at 29.5 --out build/waveform/main.png  # any ref
$W compare "<file>" --at 29.5 --out build/waveform/cmp.png           # main on top, the working tree below
$W compare "<file>" --base v1.16 --head main --at 29.5 --out build/waveform/cmp.png
$W draw "<file>" --at 29.5 --sections --levels 0.01                  # what the picture is drawn from
$W options                                                            # every probe option
```

The first build of a ref takes a few minutes. A commit's binary is kept under `build/bench-components/bin/`, and the working tree rebuilds incrementally. Write pictures under `build/` or the scratchpad, never into the tree.

## Matching a screenshot

**The defaults are an iPhone 17 Pro's card**: 402 by 180 pt at 3x, Spectrum, RGB, By section, dark, the playhead line at the center. `--at` is the time under the playhead. The screenshot's elapsed label rounds down, so try the second it shows and the half second after.

**The zoom defaults to the style's deepest.** A screenshot with about eight beats across the view is at the deepest zoom. `--span` sets seconds across the view, and `--fraction 0.48` is the scrubber's zoom at rest. The zoom is clamped as the scrubber clamps it, and the probe prints the zoom it drew. `--style` takes any registry identifier: `detailed`, `three_band`, `spectrum`, `basic` and the rest. `--precise`, `--palette blue` and `--light` set the rest of the look. A Detailed style at deep zoom reads the file's own samples, as the scrubber's delegate does.

**A user's track is usually findable.** Search Spotlight by the title in the screenshot, `mdfind "kMDItemFSName == '*<title>*'c"`. Never copy a user's music into the repository.

## What it prints

- `--sections` lists Spectrum's sections over the whole track: each one's start in seconds and the low, mid and high share of its mix. A wrong color edge is usually visible here before it is visible in a picture.
- `--levels STEP` lists, every STEP seconds across the view, the mix's peaks and loudest window and each band's loudest window. These are the numbers every height is drawn from (`Vibe/WaveformUI/Renderers/AGENTS.md`, Level mapping). A shape question, such as a round kick, is settled here. Compare the peaks, which jump at a hit, with the loudest windows, which build.
- `--deliveries DIR` replays a streaming load: a snapshot every `--every` seconds of audio (default 10), each drawn settled as `DIR/NNN.png`, the complete waveform last. `compare` also tiles each side's into `DIR/base.png` and `DIR/head.png`. A Mac decodes a local file before the loader's first 0.1 s delivery, so the replay stands in for a phone's or a stream's pace. It draws targets, not the morph's ease between them.

## Traps

- **Pictures are drawn settled.** The morph's ease, the scroll and the display link are not in them. Motion, smoothness and timing need the app (`vibe-debug`).
- **The bench builds Release, so no `#if DEBUG` seam runs**, such as the debug decode pace. That is why `--deliveries` replays the decode itself.
- **An older ref lacks newer probe features.** `perf.py` writes feature flags for a grafted ref, and a probe feature the ref's sources lack prints that it is missing rather than failing the build (`--sections` before `VibeSpectrumSections`). A ref with no Spectrum renderer or no zoom steps cannot build the probe at all, and `--waveform` answers that its build has none.
- **Keep the probe's view in step with the scrubber.** It copies `WaveformScrubberView`'s window, zoom clamp, Normalize, playhead line and Wiggle's sampling width. A change to any of those there needs the same here, or the probe draws something the phone does not.

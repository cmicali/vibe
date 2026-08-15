# Test audio fixtures

Generated fixtures for driving the app; see the `vibe-debug` skill for everything else.

Use the generated files in `Assets/test_audio_files/` (gitignored) rather than synthesizing your own:

```bash
.claude/skills/vibe-debug/scripts/generate-test-audio.sh   # idempotent; --force regenerates
```

| File | For |
| --- | --- |
| `tone-short-1.wav` / `-2` / `-3` | single-file and playlist/multi-file tests (8s, distinct pitches) |
| `tone-long.wav` | seek and skip tests (120s — skips reach ±60s) |
| `tone.flac` | FLAC/codec-label coverage |
| `tone-art-red.m4a` / `tone-art-blue.m4a` | tagged metadata (titles "Red Art Test"/"Blue Art Test", artist "Art Tester") with solid red/blue covers — art, header-tint, and dock-icon tests; play one then the other to exercise the art crossfade and tint animation. 180s, so scrubbing is testable (the iOS scrubber needs it) |
| `bpm-85.wav`, `bpm-120.wav`, `bpm-128.wav`, `bpm-140.wav`, `bpm-174.wav` | 30s kick+hat loops at exactly the named tempo — BPM-analyzer tests (see `scan-bpm.sh` below; compare against the filename). Atonal, so they double as the key analyzer's negative case: `scan-key.sh` must report no key |
| `key-am.wav`, `key-c.wav`, `key-fsm.wav`, `key-eb.wav` | 24s chord-progression loops in the named key (Am, C, F#m, Eb) — key-analyzer tests (see `scan-key.sh` below) |
| `tone-cbr.mp3` | 8s 192kbps CBR — the plain MP3 case |
| `tone-vbr.mp3` | 120s VBR with a Xing/LAME header — duration and seek accuracy, which a CBR file cannot prove because a constant-bitrate guess is right by construction |
| `tone-art-green.mp3` | 8s CBR, ID3v2 title "Green Art Test" / artist "Art Tester" and a green front cover (APIC type 3) — the ID3 art path, which shares no parser with the MP4 art above |

**The MP3s are the one part of the corpus that needs a non-stock tool** — `lame` or `ffmpeg`, either works — and the generator skips them with a note when neither is installed, so a machine without one has a corpus missing the app's headline format. `afconvert` cannot stand in: `afconvert -hf` advertises `'MPG3'` with data_formats `'.mp3'`, but encoding fails with `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')` because macOS ships an MP3 decoder and no encoder. Don't spend a round on its flags.

The short files end after eight seconds. Pause early, or use `tone-long.wav`, when a test needs playback still running at capture time.

**Simulating a slow cloud file open.** The Loading state, the shimmer, the load-timeout error and anything else gated on `didBeginLoading:` need an open that blocks, which no local file provides:

```bash
.claude/skills/vibe-debug/scripts/slow-open.sh           # app enters Loading; shimmer at 0.5s, inline timeout error at 20s
.claude/skills/vibe-debug/scripts/slow-open.sh cleanup   # after your checks — fails a still-pending open instantly (into the inline error) and removes the pipe
```

It opens a named pipe in the app container's tmp. `AVAudioFile`'s open blocks reading it forever, exactly as it would on an undownloaded iCloud or Dropbox placeholder.

**One-shot BPM and key measurement.** `scan_bpm` (and its twin `scan_key`) runs in the CLI's own process with no channel round-trip: no app launch, no window, no caches. It works with no app running and leaves a running Vibe instance untouched. The script streams the file through stdin (`scan_bpm - < file`) because the direct-exec'd binary is still sandboxed and cannot read arbitrary argv paths, for the same reason argv opens fail. The client stages the bytes in its own container tmp, which keeps shell processes out of `~/Library/Containers/` and so avoids the TCC prompt described under Screenshots:

```bash
.claude/skills/vibe-debug/scripts/scan-bpm.sh <audio-file>   # {"ok":true,"bpm":120.01} — bpm 0 = no confident tempo
.claude/skills/vibe-debug/scripts/scan-key.sh <audio-file>   # {"ok":true,"key":"Am","camelot":"8A","index":21} — empty strings / index -1 = no confident key
```

`scan_key` has the same contract as `scan_bpm` throughout: it runs in the CLI process, needs no app, ignores caches and tags (it reports pure analysis — the app's own display prefers a tagged key), and streams the file via stdin for the same sandbox reasons.


---
name: vibe-audio-quality
description: Check and document Vibe's audio quality and conformance. Runs public conformance and torture corpora (IETF CELLAR FLAC files, ISO/IEC 14496-26 Layer III, FFmpeg FATE samples, McGill WAVE and AIFF samples, EBU BW64 tests, Chromium and Firefox media tests, TagLib test data) through the real decoders. Valid files must match their FLAC MD5 or reference decode within the ISO accuracy limits, decode to the length the handle states and seek exactly. Every file must finish with finite samples. Also regenerates docs/audio-quality.md's charts and its corpus results matrix. Use after changing a decoder, a parser, the file-open path or the resampler, before a release, when asked whether decoding is correct or conformant, or to update the audio quality page.
---

# Audio quality and conformance

This skill owns `docs/audio-quality.md`: its charts, its numbers and its corpus results. The generated fixtures in `make test-audio` check what Vibe was built to do. The public corpora here check it against answers other people wrote down, on files nobody here made.

## Running a corpus

```bash
S=.claude/skills/vibe-audio-quality/scripts
python3 $S/corpus.py list                  # each corpus, and whether it is downloaded
python3 $S/corpus.py run flac              # fetch it if missing, check it, record the results
python3 $S/corpus.py run all               # every corpus, one after another
python3 $S/corpus.py run fate --no-record  # check without touching the page's results
python3 $S/corpus.py fetch mp3-iso         # only download
```

A corpus downloads into `build/audio-quality/corpora/<name>/`. Only the files Vibe plays are kept, by `Common/PlayableExtensions.m`'s list, beside the reference decodes. **Nothing downloaded is ever committed.** `make clean` deletes the downloads. The next run fetches them again.

| Name | What it holds | What it checks |
| --- | --- | --- |
| `flac` | IETF CELLAR FLAC test files: subset, uncommon and faulty | The STREAMINFO MD5, bit for bit. Faulty files must only finish. |
| `mp3-iso` | ISO/IEC 14496-26 ed. 2: every MPEG-1, 2 and 2.5 Layer III stream, with ISO's reference WAVs | Each stream against its reference, to ISO/IEC 11172-4's limits |
| `fate` | FFmpeg's FATE samples, audio folders only | The MP3 conformance streams and Xiph's Vorbis vectors against their reference decodes. The rest must finish. |
| `wav` | McGill's WAVE and AIFF samples, EBU's libbw64 test data | Robustness |
| `browser` | Chromium's `media/test/data` and Firefox's `dom/media/test` | Robustness |
| `taglib` | TagLib 2.3.2's `tests/data` | Robustness |

Each source is pinned in `corpus.py`: a commit, a tag or ISO's dated archive. McGill's pages and FATE are not versioned, but FATE never replaces a sample.

## What the test checks

`Tests/AudioRender/AudioQualityCorpusTests.m` walks the folder `corpus.py` names in `VIBE_AUDIO_QUALITY_CORPUS`. Without one it skips, so `make test-audio` never reads a corpus. The skip is on the allowed list for that reason.

**A file is valid** when it has a reference decode beside it, or it is a FLAC whose MD5 the corpus vouches for. `MD5_VOUCHED` in `corpus.py` names those paths: only CELLAR's `subset/` and `uncommon/`. Other sets keep shortened copies of real files, whose STREAMINFO still states the whole file's MD5. A valid file fails when it:
- is refused;
- differs from its MD5;
- misses its reference;
- decodes to a length other than the one the handle states;
- lands a seek on other samples than the continuous decode.

**Every file**, valid or not, fails on a hang (300 s) or a sample that is not finite. A crash ends the run, and `corpus.py` names the file it died on. A file of unknown validity may be refused: many are video, or formats Vibe does not play. One that opens and then misbehaves is a warning: a read that fails, a length the decode does not reach, or a seek that lands elsewhere.

**A known result is a file the corpus itself gets wrong.** `KNOWN` in `corpus.py` lists each one with its reason, and it counts as known, not failed. Add one only after showing the corpus is wrong. For a reference decode, that means a second decoder that agrees with Vibe, not the reference.

- **Reference decodes** sit beside the file as `<file>.ref.f32`, `.ref.s16` or `.ref.wav`. A reference of 24 bits or more is held to ISO/IEC 11172-4's full accuracy: RMS under 2⁻¹⁵/√12 and no sample off by more than 2⁻¹⁴. A 16-bit one is held to limited accuracy: RMS under 2⁻¹¹/√12.
- **TRAP: an MPEG reference keeps Layer III's 529-frame synthesis delay at its start.** The handle drops it. So the comparison starts 529 frames into the reference and leaves out the last 529 frames.
- **TRAP: ISO's decoder may leave out up to two leading frames it cannot decode.** Each one moves the reference 1152 frames earlier. The test tries zero, one and two left out, and keeps the closest. The record's `leftOut` says which matched.
- **An integer reference cannot hold an over.** Vibe's decode is clipped to the reference's range before the comparison.
- **The FLAC MD5 is skipped above 24 bits.** The decode is float32, which holds 24.
- **Apple's decoders are not held to exact seeks.**

## Reading the results

`corpus.py run` prints a table for each top-level folder of the corpus, then lists the failures and warnings. `build/audio-quality/<name>.json` has a record for each file: its decoder, rate, channels, stated and decoded length, and each check's result. `build/audio-quality/<name>.log` is the test run.

Sort what a run finds into three kinds:
1. **A decoder or parser bug.** Make the case from generated fixtures, as `Tests/AGENTS.md` says, and add a test that fails before the fix. Never copy a corpus file into the repository.
2. **A file of unknown validity that is broken in a way Vibe handles sensibly.** Leave it as a warning.
3. **A known limit**, such as a format Vibe does not play. Write it down where the page or the code already explains the limit.

## The audio quality page

- `python3 scripts/docs/audio_quality.py` redraws every chart on `docs/audio-quality.md`. The numbers live in that script. The resampler's frequency response curves live in `docs/audio-quality/response.json`.
- A recorded run writes its summary to `docs/audio-quality/corpora.json` and redraws `corpus-results.svg`, the page's corpus matrix.
- Commit the page, the JSON and the redrawn SVGs together. Name the corpora and the date in the commit message.
- When a decoder change moves a number on the page, measure again with the test or benchmark the page names. Then edit the number in `audio_quality.py`, and redraw.
- The page's text follows the root `AGENTS.md` rule: short, plain sentences.

## Traps

- **ISO's files may be used unmodified, for the standard's purposes.** `corpus.py` fetches them on demand and only renames the streams to `.mp3`. FATE states no licence. Fetch both, and never commit them.
- **The Firefox listing uses GitHub's API, which allows 60 calls an hour without a token.** A fetch needs two.
- **A file Vibe does not play by its extension is skipped,** such as McGill's `.aifc` files. `corpus.py fetch` says how many it skipped.
- **The FLAC corpus is about 310 MB,** most of it hi-res files and one 15.8 MB picture.

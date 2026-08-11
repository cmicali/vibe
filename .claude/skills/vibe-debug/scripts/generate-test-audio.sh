#!/bin/bash
# Generates the standard test audio files into Assets/test_audio_files/
# (gitignored). Idempotent: existing files are kept unless --force is given.
# Uses only tools present on a stock dev Mac: python3, afconvert, swift.
#
#   tone-short-1.wav / -2 / -3   8s stereo WAVs at distinct pitches — playlist,
#                                multi-file, and Close All tests
#   tone-long.wav                120s WAV — seek and skip-forward/back tests
#                                (skips reach ±60s)
#   tone.flac                    8s FLAC — codec-label / format coverage
#   bpm-85.wav ... bpm-174.wav   30s kick+hat drum loops at exact BPMs (85,
#                                120, 128, 140, 174) — BPM-analyzer tests
#                                (scan-bpm.sh prints the detected bpm; compare
#                                against the filename)
#   key-am.wav / key-c.wav /     24s chord-progression loops in the named key
#   key-fsm.wav / key-eb.wav     (Am, C, F#m, Eb) — key-analyzer tests
#                                (scan-key.sh prints the detected key; the
#                                bpm-*.wav loops double as the atonal
#                                negative case, expecting no key)
#   tone-art-red.m4a             8s AAC tagged with title/artist and a solid
#   tone-art-blue.m4a            red/blue cover — art, header-tint, and
#                                dock-icon tests; play one after the other to
#                                exercise the art crossfade and tint animation
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
OUT="$REPO_ROOT/Assets/test_audio_files"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
mkdir -p "$OUT"

have() { [ $FORCE -eq 0 ] && [ -s "$OUT/$1" ]; }

# Amplitude-modulated sine WAV: gen_wav <path> <freq_hz> <seconds>
gen_wav() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, wave, math, struct
path, freq, secs = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rate = 44100
w = wave.open(path, 'w')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
frames = bytearray()
for i in range(int(rate * secs)):
    # 2 Hz tremolo so the waveform view shows visible structure, not a bar.
    v = int(12000 * math.sin(2 * math.pi * freq * i / rate)
                  * (0.5 + 0.5 * math.sin(2 * math.pi * 2 * i / rate)))
    frames += struct.pack('<hh', v, v)
w.writeframes(bytes(frames)); w.close()
PY
}

have tone-short-1.wav || gen_wav "$OUT/tone-short-1.wav" 220 8
have tone-short-2.wav || gen_wav "$OUT/tone-short-2.wav" 330 8
have tone-short-3.wav || gen_wav "$OUT/tone-short-3.wav" 440 8
have tone-long.wav    || gen_wav "$OUT/tone-long.wav"    220 120

if ! have tone.flac; then
    afconvert -f flac -d flac "$OUT/tone-short-1.wav" "$OUT/tone.flac"
fi

# Kick/hat drum loop at an exact tempo: gen_bpm_wav <path> <bpm> <seconds>.
# Kick (40-120 Hz sweep) on every beat, hat (noise burst) on the offbeats —
# strong low-frequency onsets on the quarter grid so the analyzer's base
# tempo is unambiguous, offbeat hats so it also sees 8th-note flux.
gen_bpm_wav() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, wave, math, struct, random
path, bpm, secs = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rate = 44100
n = int(rate * secs)
buf = [0.0] * n
beat = 60.0 / bpm
kick_len = int(0.12 * rate)
hat_len = int(0.03 * rate)
random.seed(1234)  # deterministic output — idempotent files
k = 0
while True:
    t = k * beat
    if t >= secs:
        break
    start = int(t * rate)
    phase = 0.0
    for i in range(min(kick_len, n - start)):
        tt = i / rate
        f = 40 + 80 * math.exp(-tt * 25)   # pitch sweep 120 -> 40 Hz
        phase += 2 * math.pi * f / rate
        buf[start + i] += 0.9 * math.exp(-tt * 28) * math.sin(phase)
    hs = int((t + beat / 2) * rate)
    for i in range(min(hat_len, max(0, n - hs))):
        tt = i / rate
        buf[hs + i] += 0.25 * math.exp(-tt * 120) * (random.random() * 2 - 1)
    k += 1
w = wave.open(path, 'w')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
frames = bytearray()
for v in buf:
    s = int(max(-1.0, min(1.0, v)) * 26000)
    frames += struct.pack('<hh', s, s)
w.writeframes(bytes(frames)); w.close()
PY
}

for bpm in 85 120 128 140 174; do
    have "bpm-$bpm.wav" || gen_bpm_wav "$OUT/bpm-$bpm.wav" "$bpm" 30
done

# Chord-progression loop in a known key: gen_key_wav <path> <root_pc> <minor>
# <seconds>. root_pc is the tonic's pitch class (0=C .. 11=B). A i-iv-v-i
# (minor) or I-IV-V-I (major) progression of sustained triads with an octave
# bass, three sine partials per tone — strongly tonal, all inside the key's
# scale, tonic-heavy, so the key analyzer's verdict is unambiguous.
gen_key_wav() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, wave, math, struct
path, root_pc, minor, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
rate = 44100
n = int(rate * secs)
buf = [0.0] * n
third = 3 if minor else 4
# Chord roots relative to the tonic, all triads in the tonic's mode quality.
progression = [0, 5, 7, 0]
chord_secs = 2.0
root_midi = 48 + root_pc  # tonic around C3-B3
def add_tone(start, dur, midi, amp):
    f = 440.0 * 2 ** ((midi - 69) / 12.0)
    length = min(int(dur * rate), n - start)
    for h, ha in ((1, 1.0), (2, 0.35), (3, 0.15)):
        w = 2 * math.pi * f * h / rate
        for i in range(length):
            env = min(1.0, i / (0.01 * rate)) * math.exp(-i / rate / 1.5)
            buf[start + i] += amp * ha * env * math.sin(w * i)
k = 0
while k * chord_secs < secs:
    start = int(k * chord_secs * rate)
    degree = progression[k % len(progression)]
    chord_root = root_midi + degree
    add_tone(start, chord_secs, chord_root - 12, 0.9)   # bass octave
    add_tone(start, chord_secs, chord_root, 0.6)
    add_tone(start, chord_secs, chord_root + third, 0.5)
    add_tone(start, chord_secs, chord_root + 7, 0.5)
    k += 1
peak = max(abs(v) for v in buf) or 1.0
w = wave.open(path, 'w')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
frames = bytearray()
for v in buf:
    s = int(v / peak * 26000)
    frames += struct.pack('<hh', s, s)
w.writeframes(bytes(frames)); w.close()
PY
}

have key-am.wav  || gen_key_wav "$OUT/key-am.wav"  9  1 24
have key-c.wav   || gen_key_wav "$OUT/key-c.wav"   0  0 24
have key-fsm.wav || gen_key_wav "$OUT/key-fsm.wav" 6  1 24
have key-eb.wav  || gen_key_wav "$OUT/key-eb.wav"  3  0 24

# Tagged AAC with a solid-color cover:
#   gen_art_m4a <output name> <source wav> <r> <g> <b> <title> <artist>
gen_art_m4a() {
    local name="$1" src="$2" r="$3" g="$4" b="$5" title="$6" artist="$7"
    # Solid 300x300 PNG for the cover, written without any imaging deps.
    python3 - "$OUT/.art.png" "$r" "$g" "$b" <<'PY'
import sys, zlib, struct
path = sys.argv[1]
r, g, b = (int(v) for v in sys.argv[2:5])
w = h = 300
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
raw = b''.join(b'\x00' + bytes([r, g, b] * w) for _ in range(h))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open(path, 'wb').write(png)
PY
    afconvert -f m4af -d aac "$src" "$OUT/.plain.m4a"
    # AVFoundation passthrough re-export to attach iTunes-style metadata
    # (title/artist/cover art) that TagLib's MP4 parser reads.
    swift - "$OUT/.plain.m4a" "$OUT/.art.png" "$OUT/$name" "$title" "$artist" <<'SWIFT'
import AVFoundation
let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1])
let artData = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
let dst = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: dst)
let asset = AVURLAsset(url: src)
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
    print("no export session"); exit(1)
}
func item(_ id: AVMetadataIdentifier, _ value: NSObject & NSCopying) -> AVMetadataItem {
    let m = AVMutableMetadataItem()
    m.identifier = id
    m.value = value
    return m
}
let art = AVMutableMetadataItem()
art.identifier = .iTunesMetadataCoverArt
art.dataType = kCMMetadataBaseDataType_PNG as String
art.value = artData as NSData
export.metadata = [art,
                   item(.iTunesMetadataSongName, args[4] as NSString),
                   item(.iTunesMetadataArtist, args[5] as NSString)]
export.outputURL = dst
export.outputFileType = .m4a
let sem = DispatchSemaphore(value: 0)
export.exportAsynchronously { sem.signal() }
sem.wait()
guard export.status == .completed else {
    print("export failed:", export.error?.localizedDescription ?? "unknown"); exit(1)
}
SWIFT
    rm -f "$OUT/.art.png" "$OUT/.plain.m4a"
}

have tone-art-red.m4a  || gen_art_m4a tone-art-red.m4a  "$OUT/tone-short-1.wav" 200 40 60  "Red Art Test"  "Art Tester"
have tone-art-blue.m4a || gen_art_m4a tone-art-blue.m4a "$OUT/tone-short-2.wav" 40 90 220  "Blue Art Test" "Art Tester"

ls -lh "$OUT"

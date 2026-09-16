#!/bin/bash
# Generates the standard test audio files into Assets/test_audio_files/
# (gitignored). Idempotent: existing files are kept unless --force is given.
# Uses only tools present on a stock dev Mac: python3, afconvert, swift —
# except the MP3s, which need lame or ffmpeg and are skipped without one, so
# the corpus is machine-dependent in that one respect. See the MP3 section.
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
#   tone-art-red.m4a             180s AAC tagged with title/artist and a solid
#   tone-art-blue.m4a            red/blue cover — art, header-tint, and
#                                dock-icon tests; play one after the other to
#                                exercise the art crossfade and tint animation.
#                                Minutes long so scrubbing is testable (iOS)
#   tone-cbr.mp3                 8s 192kbps CBR — the plain MP3 case
#   tone-vbr.mp3                 120s VBR (Xing/LAME header) — duration and
#                                seek accuracy, where a CBR file proves nothing
#                                because a bitrate guess happens to be right
#   tone-art-green.mp3           8s CBR tagged ID3v2 with title/artist and a
#                                green cover — the ID3 path, which shares no
#                                parser with the MP4 art above
set -euo pipefail

# Driver fixtures remain outside the app and the repository's vendored sources.
if [ "${1:-}" = "--blackhole-drivers" ]; then
    python3 - "${2:-build/blackhole-drivers}" <<'DRIVER_PY'
import pathlib, plistlib, re, subprocess, sys, uuid

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
revision = 'ffcb74433fbcf8c8ca5c736677c1a4864384dc09'
source = root/'upstream'
def run(*args):
    subprocess.run(args, check=True)
if not source.exists():
    run('git', 'clone', '--no-checkout', 'https://github.com/ExistentialAudio/BlackHole.git', str(source))
run('git', '-C', str(source), 'fetch', '--depth=1', 'origin', revision)
original = subprocess.check_output(['git', '-C', str(source), 'show', revision+':BlackHole/BlackHole.c'], text=True)
license_text = subprocess.check_output(['git', '-C', str(source), 'show', revision+':LICENSE'], text=True)

# Public AudioServerPlugIn custom properties: a leased fault mask and a hit
# counter. Expiry limits damage if the verifier itself is killed before cleanup.
state = r'''
#include <stdatomic.h>
#include <time.h>
static _Atomic(unsigned) gVibeTestFault = 0, gVibeTestHits = 0;
static _Atomic(time_t) gVibeTestExpiry = 0;
static unsigned VibeTestFault(void) {
    return time(NULL) < atomic_load(&gVibeTestExpiry) ? atomic_load(&gVibeTestFault) : 0;
}
'''
custom = "(inObjectID == kObjectID_Device || inObjectID == kObjectID_Box) && inAddress && (inAddress->mSelector == 'vbtf' || inAddress->mSelector == 'vbth')"
info = "(inObjectID == kObjectID_Device || inObjectID == kObjectID_Box) && inAddress && inAddress->mSelector == kAudioObjectPropertyCustomPropertyInfoList"
hooks = {
'HasProperty': f'if ({custom} || ({info})) return true;',
'IsPropertySettable': f'if ({custom}) {{ *outIsSettable = inAddress->mSelector == \'vbtf\'; return noErr; }}\n'
                     f'if ({info}) {{ *outIsSettable = false; return noErr; }}',
'GetPropertyDataSize': f'if ({custom}) {{ *outDataSize = sizeof(CFNumberRef); return noErr; }}\n'
                      f'if ({info}) {{ *outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo); return noErr; }}',
'GetPropertyData': f'''
    if ({custom}) {{
        if (inDataSize < sizeof(CFNumberRef)) return kAudioHardwareBadPropertySizeError;
        SInt32 value = inAddress->mSelector == 'vbtf' ? VibeTestFault() : atomic_load(&gVibeTestHits);
        *(CFNumberRef*)outData = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
        *outDataSize = sizeof(CFNumberRef); return noErr;
    }}
    if ({info}) {{
        AudioServerPlugInCustomPropertyInfo entries[] = {{
            {{'vbtf', kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone}},
            {{'vbth', kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone}}
        }};
        if (inDataSize < sizeof(entries)) return kAudioHardwareBadPropertySizeError;
        memcpy(outData, entries, sizeof(entries)); *outDataSize = sizeof(entries); return noErr;
    }}
    unsigned fault = VibeTestFault();
    if (inAddress && inObjectID == kObjectID_Volume_Output_Master
            && inAddress->mSelector == kAudioLevelControlPropertyScalarValue && (fault & 7)) {{
        atomic_fetch_add(&gVibeTestHits, 1);
        if (fault & 1) return kAudioHardwareUnspecifiedError;
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        *(Float32*)outData = NAN; *outDataSize = fault & 4 ? 0 : sizeof(Float32); return noErr;
    }}
    if (inAddress && ((inObjectID == kObjectID_Stream_Output
            && inAddress->mSelector == kAudioStreamPropertyPhysicalFormat && (fault & 8))
            || (inObjectID == kObjectID_Device
            && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate && (fault & 64)))) {{
        atomic_fetch_add(&gVibeTestHits, 1); return kAudioHardwareUnspecifiedError;
    }}
    if (inAddress && inObjectID == kObjectID_Device
            && inAddress->mSelector == kAudioDevicePropertyDeviceIsAlive && (fault & 128)) {{
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        atomic_fetch_add(&gVibeTestHits, 1);
        *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
    }}
''',
'SetPropertyData': f'''
    if ({custom}) {{
        if (inAddress->mSelector != 'vbtf' || inDataSize != sizeof(CFNumberRef) || !inData)
            return kAudioHardwareBadPropertySizeError;
        CFNumberRef number = *(CFNumberRef const*)inData;
        SInt32 mask = 0;
        if (!number || CFGetTypeID(number) != CFNumberGetTypeID()
                || !CFNumberGetValue(number, kCFNumberSInt32Type, &mask) || mask < 0 || mask > 255)
            return kAudioHardwareIllegalOperationError;
        atomic_store(&gVibeTestHits, 0);
        atomic_store(&gVibeTestExpiry, time(NULL) + 60);
        atomic_store(&gVibeTestFault, mask);
        AudioObjectPropertyAddress address = {{kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Volume_Output_Master, 1, &address);
        address.mSelector = kAudioStreamPropertyPhysicalFormat;
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Stream_Output, 1, &address);
        AudioObjectPropertyAddress deviceAddresses[] = {{
            {{kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}},
            {{kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}}
        }};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 2, deviceAddresses);
        return noErr;
    }}
    if (inAddress && inObjectID == kObjectID_Stream_Output
            && inAddress->mSelector == kAudioStreamPropertyPhysicalFormat && (VibeTestFault() & 48)) {{
        atomic_fetch_add(&gVibeTestHits, 1);
        return VibeTestFault() & 16 ? kAudioHardwareUnspecifiedError : noErr;
    }}
'''
}
staging = root/'package-root'/'Library'/'Audio'/'Plug-Ins'/'HAL'
for name, channels, bare, limited in [('VibeBlackHole', 16, False, False),
                                     ('VibeBlackHoleBare', 16, True, False),
                                     ('VibeBlackHole48', 2, False, True)]:
    bundle_id = 'com.commonwealthrecordings.vibe.test.'+name.lower()
    product = name+str(channels)+'ch'
    code = original
    if name == 'VibeBlackHole':
        code = state + code
        for method, hook in hooks.items():
            pattern = r'(static (?:Boolean|OSStatus)\s+BlackHole_'+method+r'\([^;]+?\)\s*\{)'
            code, count = re.subn(pattern, lambda m: m[0]+'\n'+hook+'\n', code, count=1)
            assert count == 1, method
    if bare:
        code, count = re.subn(r'^.*\{ kObjectID_(?:Volume|Mute)_[^\n]+\n', '', code, flags=re.M)
        assert count == 8, count
    definitions = f'#define kDriver_Name "{name}"\n#define kPlugIn_BundleID "{bundle_id}"\n#define kNumber_Of_Channels {channels}\n'
    definitions += '#define kCanBeDefaultDevice false\n#define kCanBeDefaultSystemDevice false\n'
    if bare: definitions += '#define kEnableVolumeControl false\n'
    if limited: definitions += '#define kSampleRates 48000\n'
    c_file = root/(product+'.c')
    c_file.write_text(definitions+code)
    check = r'''
#include <assert.h>
int main(void) {
    for (unsigned i = 0; i < kDevice_ObjectListSize; ++i) {
        if (kEnableVolumeControl) break;
        assert(kDevice_ObjectList[i].id != kObjectID_Volume_Input_Master);
        assert(kDevice_ObjectList[i].id != kObjectID_Volume_Output_Master);
        assert(kDevice_ObjectList[i].id != kObjectID_Mute_Input_Master);
        assert(kDevice_ObjectList[i].id != kObjectID_Mute_Output_Master);
    }
    return 0;
}
'''
    if name == 'VibeBlackHole':
        check = r'''
#include <assert.h>
static OSStatus VibeTestNotify(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) { return noErr; }
int main(void) {
    AudioServerPlugInHostInterface host = {.PropertiesChanged = VibeTestNotify};
    gPlugIn_Host = &host;
    AudioObjectPropertyAddress address = {'vbtf', kAudioObjectPropertyScopeGlobal, 0};
    for (SInt32 mask = 1; mask <= 128; mask *= 2) {
        address.mSelector = 'vbtf';
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &mask);
        assert(BlackHole_SetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address, 0, NULL, sizeof(number), &number) == noErr);
        CFRelease(number);
        UInt32 size = 0; CFNumberRef readback = NULL; SInt32 readMask = 0;
        assert(BlackHole_GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address, 0, NULL, sizeof(readback), &size, &readback) == noErr);
        assert(CFNumberGetValue(readback, kCFNumberSInt32Type, &readMask) && readMask == mask); CFRelease(readback);
        AudioStreamBasicDescription data = {0};
        AudioObjectID object = kObjectID_Stream_Output;
        address.mSelector = kAudioStreamPropertyPhysicalFormat;
        if (mask < 8) { object = kObjectID_Volume_Output_Master; address.mSelector = kAudioLevelControlPropertyScalarValue; }
        if (mask >= 64) { object = kObjectID_Device; address.mSelector = mask == 64 ? kAudioDevicePropertyNominalSampleRate : kAudioDevicePropertyDeviceIsAlive; }
        OSStatus status = (mask == 16 || mask == 32)
            ? BlackHole_SetPropertyData(gAudioServerPlugInDriverRef, object, 0, &address, 0, NULL, sizeof(data), &data)
            : BlackHole_GetPropertyData(gAudioServerPlugInDriverRef, object, 0, &address, 0, NULL, sizeof(data), &size, &data);
        assert(atomic_load(&gVibeTestHits) == 1);
        assert(status == ((mask == 1 || mask == 8 || mask == 16 || mask == 64) ? kAudioHardwareUnspecifiedError : noErr));
        if (mask == 2) assert(isnan(*(Float32*)&data) && size == sizeof(Float32));
        if (mask == 4) assert(size == 0);
        if (mask == 128) assert(*(UInt32*)&data == 0);
        assert(gDevice_SampleRate == 48000);
    }
    atomic_store(&gVibeTestExpiry, time(NULL)-1); assert(VibeTestFault() == 0);
    return 0;
}
'''
    test_file = root/(product+'-check.c')
    test_file.write_text(definitions+code+check)
    test_binary = root/(product+'-check')
    run('xcrun', 'clang', '-fblocks', '-std=gnu11', '-O0', '-framework', 'CoreAudio', '-framework', 'CoreFoundation',
        '-framework', 'Accelerate', str(test_file), '-o', str(test_binary))
    run(str(test_binary))
    bundle = staging/(product+'.driver')
    (bundle/'Contents'/'MacOS').mkdir(parents=True, exist_ok=True)
    (bundle/'Contents'/'Resources').mkdir(exist_ok=True)
    (bundle/'Contents'/'Resources'/'LICENSE').write_text(license_text)
    factory = str(uuid.uuid5(uuid.NAMESPACE_DNS, bundle_id))
    with (bundle/'Contents'/'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleExecutable': product, 'CFBundleIdentifier': bundle_id,
                      'CFBundleName': product, 'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1',
                      'CFBundleShortVersionString': '0.7.1',
                      'CFPlugInFactories': {factory: 'BlackHole_Create'},
                      'CFPlugInTypes': {'443ABAB8-E7B3-491A-B985-BEB9187030DB': [factory]},
                      'VibeBlackHoleRevision': revision}, f)
    run('xcrun', 'clang', '-bundle', '-fblocks', '-std=gnu11', '-O2', '-arch', 'arm64', '-arch', 'x86_64',
        '-mmacosx-version-min=13.0', '-framework', 'CoreAudio', '-framework', 'CoreFoundation',
        '-framework', 'Accelerate', str(c_file), '-o', str(bundle/'Contents'/'MacOS'/product))
    run('codesign', '--force', '--sign', '-', str(bundle))
run('pkgbuild', '--root', str(root/'package-root'), '--identifier', 'com.commonwealthrecordings.vibe.test.blackhole',
    '--version', '1', '--ownership', 'recommended', str(root/'VibeBlackHoleTests.pkg'))
print('Built', root/'VibeBlackHoleTests.pkg')
print('Install this package with macOS Installer, then restart CoreAudio or reboot before testing.')
DRIVER_PY
    exit 0
fi

# Analytical fixtures for the real-player render suite. No third-party encoder
# is required for the core matrix. Optional MPEG fixtures are explicitly skipped
# by XCTest when ffmpeg is absent, rather than pretending those codecs passed.
if [ "${1:-}" = "--render-tests" ]; then
    render_dir="${2:?usage: --render-tests <output-directory>}"
    mkdir -p "$render_dir"
    python3 - "$render_dir" <<'AUDIO_PY'
from pathlib import Path
import math, struct, sys, json
out=Path(sys.argv[1])
def wav(name, rate, bits, channels, kind='noise', seconds=2, floating=False, marker=False):
    path=out/name
    if path.exists(): return
    state=0x12345678
    data=bytearray()
    for n in range(int(rate*seconds)):
        for c in range(channels):
            state=(1664525*state+1013904223)&0xffffffff
            if kind in ['noise','integer32'] or (marker and n<rate//10):
                value=(state/2147483648-1)*0.25 if bits==64 else ((state>>8)/8388608-1)*0.25
            elif kind=='silence': value=0
            elif kind=='impulse': value=0.5 if n==int(rate*0.25) else 0
            elif kind=='limits':
                quantum=2**-(23 if floating else bits-1)
                value=((state>>8)/8388608-1)*0.25 if n<rate//10 else [0,1-quantum,-1,quantum,-quantum][(n+c)%5]
            elif kind=='sweep': value=0.25*math.sin(2*math.pi*(10*n/rate+(rate*0.45-10)*(n/rate)**2/(2*seconds)))
            else: value=0.25*math.sin(2*math.pi*float(kind)*(c+1)*n/rate)
            if floating: data.extend(struct.pack('<d' if bits==64 else '<f',value))
            else:
                sample=(state>>2)-(1<<29) if kind=='integer32' else round(value*(1<<(bits-1)))
                sample=max(-(1<<(bits-1)), min((1<<(bits-1))-1,sample))
                data.extend(sample.to_bytes(bits//8,'little',signed=True))
    fmt=struct.pack('<HHIIHH',3 if floating else 1,channels,rate,rate*channels*(bits//8),channels*(bits//8),bits)
    path.write_bytes(b'RIFF'+struct.pack('<I',36+len(data))+b'WAVEfmt '+struct.pack('<I',16)+fmt+b'data'+struct.pack('<I',len(data))+data)
for rate in [44100,48000,88200,96000,176400,192000]:
    for bits in [16,24,32]:
        for channels in [1,2]:
            wav(f'noise-{rate}-{bits}-{channels}.wav',rate,bits,channels,floating=bits==32)
for channels in [4,8,16]:
    wav(f'noise-48000-24-{channels}.wav',48000,24,channels)
for kind in ['silence','impulse','limits','sweep','20','100','1000','8000','23000']:
    wav(f'{kind}.wav',48000,32,2,kind,seconds=8 if kind in ['silence','impulse'] else 4,floating=True)
for rate in [44100,48000,96000]:
    wav(f'tone-{rate}.wav',rate,32,2,'1000',seconds=4,floating=True)
for bits in [16,24]:
    wav(f'limits-{bits}.wav',48000,bits,2,'limits')
for kind in ['silence','impulse','sweep']:
    wav(f'marked-{kind}.wav',48000,32,2,kind,floating=True,marker=True)
# Keep nonzero low bits: scaling 24-bit noise into int32 cannot expose float32 loss.
wav('integer32-low-bits.wav',48000,32,2,'integer32')
wav('float64-low-bits.wav',48000,64,2,floating=True)
wav('integer32.wav',48000,32,2)
(out/'manifest.json').write_text(json.dumps({'seed':'0x12345678','rates':[44100,48000,88200,96000,176400,192000],'duration':2,'noisePeak':0.25},indent=2))
AUDIO_PY
    render_source="$render_dir/noise-48000-24-2.wav"
    [ -s "$render_dir/lossless.flac" ] || afconvert -f flac -d flac "$render_source" "$render_dir/lossless.flac"
    [ -s "$render_dir/lossless.m4a" ] || afconvert -f m4af -d alac "$render_source" "$render_dir/lossless.m4a"
    [ -s "$render_dir/lossless.aiff" ] || afconvert -f AIFF -d BEI24 "$render_source" "$render_dir/lossless.aiff"
    [ -s "$render_dir/lossy.m4a" ] || afconvert -f m4af -d aac -b 192000 "$render_source" "$render_dir/lossy.m4a"
    for ext in aif wave bwf; do
        if [ "$ext" = aif ]; then render_copy="$render_dir/lossless.aiff"; else render_copy="$render_source"; fi
        [ -s "$render_dir/alias.$ext" ] || cp "$render_copy" "$render_dir/alias.$ext"
    done
    [ -s "$render_dir/alias.mp4" ] || cp "$render_dir/lossy.m4a" "$render_dir/alias.mp4"
    [ -s "$render_dir/lossy.aac" ] || afconvert -f adts -d aac -b 192000 "$render_source" "$render_dir/lossy.aac"
    if command -v ffmpeg >/dev/null; then
        [ -s "$render_dir/cbr.mp3" ] || ffmpeg -nostdin -loglevel error -y -i "$render_source" -c:a libmp3lame -b:a 192k "$render_dir/cbr.mp3"
        [ -s "$render_dir/vbr.mp3" ] || ffmpeg -nostdin -loglevel error -y -i "$render_source" -c:a libmp3lame -q:a 2 "$render_dir/vbr.mp3"
        [ -s "$render_dir/lossy.mp2" ] || ffmpeg -nostdin -loglevel error -y -i "$render_source" -c:a mp2 -b:a 192k "$render_dir/lossy.mp2"
        [ -s "$render_dir/lossy.qta" ] || ffmpeg -nostdin -loglevel error -y -i "$render_source" -c:a aac -f mov "$render_dir/lossy.qta"
    fi
    exit 0
fi

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

# The rates set, for bit-perfect output: the long tone at the rates and word
# lengths a DAC is asked for, so a loopback can prove each arrives unchanged
# (verify-bit-perfect.swift). Deterministic content, known rate and depth.
mkdir -p "$OUT/rates"
for spec in 44100-16 48000-16 88200-24 96000-24; do
    have "rates/tone-$spec.wav" \
        || afconvert -f WAVE -d "LEI${spec#*-}@${spec%-*}" "$OUT/tone-long.wav" "$OUT/rates/tone-$spec.wav"
done
have rates/tone-96000-24.flac || afconvert -f flac -d flac "$OUT/rates/tone-96000-24.wav" "$OUT/rates/tone-96000-24.flac"

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

# Solid 300x300 PNG cover, written without any imaging deps:
#   gen_png <path> <r> <g> <b>
gen_png() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
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
}

# Tagged AAC with a solid-color cover:
#   gen_art_m4a <output name> <source wav> <r> <g> <b> <title> <artist>
gen_art_m4a() {
    local name="$1" src="$2" r="$3" g="$4" b="$5" title="$6" artist="$7"
    gen_png "$OUT/.art.png" "$r" "$g" "$b"
    afconvert -f m4af -d aac "$src" "$OUT/.plain.m4a"
    # AVFoundation passthrough re-export to attach iTunes-style metadata
    # (title/artist/embedded art) that TagLib's MP4 parser reads.
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

# Minutes-long sources so the art files can exercise scrubbing; the temp
# tones are distinct pitches like the shorts.
if ! have tone-art-red.m4a; then
    gen_wav "$OUT/.art-src-1.wav" 220 180
    gen_art_m4a tone-art-red.m4a  "$OUT/.art-src-1.wav" 200 40 60  "Red Art Test"  "Art Tester"
    rm -f "$OUT/.art-src-1.wav"
fi
if ! have tone-art-blue.m4a; then
    gen_wav "$OUT/.art-src-2.wav" 330 180
    gen_art_m4a tone-art-blue.m4a "$OUT/.art-src-2.wav" 40 90 220  "Blue Art Test" "Art Tester"
    rm -f "$OUT/.art-src-2.wav"
fi

# ---------------------------------------------------------------------------
# MP3 — the one part of the corpus needing a non-stock tool.
#
# afconvert cannot encode MP3, and its help actively misleads: `afconvert -hf`
# lists 'MPG3' = MPEG Layer 3 with data_formats '.mp3', so the format looks
# writable, but the encode dies with
#     Error: ExtAudioFileSetProperty ('cfmt') failed ('fmt?')
# because macOS ships an MP3 decoder and no encoder. Do not spend another round
# on afconvert flags; reach for lame or ffmpeg (either works, lame preferred as
# the smaller dep) and skip the files when neither is installed rather than
# failing the whole corpus.
# ---------------------------------------------------------------------------
MP3ENC=""
command -v lame   >/dev/null 2>&1 && MP3ENC=lame
[ -z "$MP3ENC" ] && command -v ffmpeg >/dev/null 2>&1 && MP3ENC=ffmpeg

# gen_mp3 <dst> <src wav> <cbr|vbr>
gen_mp3() {
    case "$MP3ENC:$3" in
        lame:cbr)   lame --quiet -b 192 "$2" "$1" ;;
        lame:vbr)   lame --quiet -V 2   "$2" "$1" ;;
        ffmpeg:cbr) ffmpeg -y -loglevel error -i "$2" -codec:a libmp3lame -b:a 192k "$1" ;;
        ffmpeg:vbr) ffmpeg -y -loglevel error -i "$2" -codec:a libmp3lame -q:a 2    "$1" ;;
    esac
}

# Stamp the APIC picture type to 3 (Front cover). Neither encoder will: lame
# has no option for it and ffmpeg defaults to 0 (Other) unless the video stream
# carries a matching comment tag, so both leave a picture that getAlbumArtID3v2
# finds only through its any-type fallback. Real files carry type 3, and a test
# asset exercising the fallback would hide a regression in the FrontCover
# branch it prefers.
set_apic_front_cover() {
    python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
d = bytearray(open(path, 'rb').read())
i = d.find(b'APIC')                 # ID3v2 precedes the audio, so this is the frame
if i < 0:
    sys.exit("no APIC frame in %s" % path)
j = d.index(b'\x00', i + 11)        # body: encoding(1), then null-terminated MIME
d[j + 1] = 3
open(path, 'wb').write(d)
PY
}

# ID3v2 title/artist/cover, which shares no parser with the MP4 art above:
#   gen_art_mp3 <dst> <src wav> <r> <g> <b> <title> <artist>
gen_art_mp3() {
    local dst="$1" src="$2" r="$3" g="$4" b="$5" title="$6" artist="$7"
    gen_png "$OUT/.art.png" "$r" "$g" "$b"
    case "$MP3ENC" in
        lame)
            lame --quiet -b 192 --id3v2-only \
                 --tt "$title" --ta "$artist" --ti "$OUT/.art.png" "$src" "$dst"
            ;;
        ffmpeg)
            # attached_pic or the image lands as a video stream some parsers
            # then read as a second track rather than as embedded art.
            ffmpeg -y -loglevel error -i "$src" -i "$OUT/.art.png" \
                   -map 0:a -map 1:v -codec:a libmp3lame -b:a 192k -codec:v copy \
                   -id3v2_version 3 -disposition:v attached_pic \
                   -metadata title="$title" -metadata artist="$artist" "$dst"
            ;;
    esac
    set_apic_front_cover "$dst"
    rm -f "$OUT/.art.png"
}

if [ -n "$MP3ENC" ]; then
    have tone-cbr.mp3       || gen_mp3 "$OUT/tone-cbr.mp3" "$OUT/tone-short-1.wav" cbr
    have tone-vbr.mp3       || gen_mp3 "$OUT/tone-vbr.mp3" "$OUT/tone-long.wav"    vbr
    have tone-art-green.mp3 || gen_art_mp3 "$OUT/tone-art-green.mp3" \
                                   "$OUT/tone-short-3.wav" 40 170 90 "Green Art Test" "Art Tester"
elif ! have tone-cbr.mp3 || ! have tone-vbr.mp3 || ! have tone-art-green.mp3; then
    # Only when something is actually missing: a machine with no encoder but a
    # corpus generated earlier is fine, and warning there reads as a problem.
    echo "note: neither lame nor ffmpeg found — skipping the MP3 files." >&2
    echo "      brew install lame, then re-run, to cover the app's headline format." >&2
fi

ls -lh "$OUT"

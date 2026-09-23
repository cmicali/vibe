# Bit-perfect output (macOS)

Implemented on `worktree-bit-perfect-output`. The current mechanism and its
maintenance rules live in [Audio/Mac/Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md).
This document keeps the measurements and verification limits; the superseded
implementation plan is available in git history.

## User behavior

- **Bit-perfect output**, off by default, requires an explicitly chosen eligible
  output device. It matches the file's rate and lossless depth; lossy files prefer
  16-bit output, then a wider integer format or floating point if needed. It removes
  varispeed, disables FX and pitch controls, and writes no volume: no crossfade,
  and no declick or fade at a start, pause, resume, seek, track change or stop.
- **Exclusive output** is a separate opt-in immediately below it. Physical and virtual devices
  may request it when the HAL hog property is writable, the device that is currently
  the system output included — taking that one makes macOS move the system default to
  another device until Vibe releases it. Shared output can still deliver
  Vibe's samples unchanged; it does not prevent other applications from mixing in.
- The header lock and Settings caption read one report. Active requires confirmed
  routing and format, matching channel counts, sufficient source precision,
  unity volume, centered balance, no mute, and a lossless source. When exclusive
  access was requested for a device that permits it, ownership must also hold.
- FX and bit-perfect switches apply live through the same playback-preserving
  rebuild. Bit-perfect bypasses retained FX nodes; turning it off restores the
  saved FX/crossfade choices. A first FX enable creates its nodes without relaunch.
- First use remembers the device's original physical format. Changing devices,
  disabling the mode, or quitting restores it. Exclusive access is released after
  an idle engine stop (6 seconds in both modes).
- With bit-perfect off, playback keeps the pre-feature mixer connection and
  varispeed timing. Neither the output-unit binding listener nor the volume,
  balance and mute listener is installed. Disabling restores that connection
  and removes both listeners before ordinary playback continues.
- A disappearing selected device disables the mode and falls back to System Output.
  An unresolved saved device at launch stays pending; this is not device removal.
- Starts, stops and every other transport edge cut rather than fade, so a cut
  mid-waveform can click; that is the price of delivering every sample unchanged.
  A sample-rate boundary needs the DAC to relock. Lossy files are decoded first;
  the mode cannot reconstruct the discarded source information.

`VIBE_ENABLE_EXCLUSIVE_OUTPUT=0` removes the exclusive row, writable preference,
player ownership state/methods, and HAL hog functions. Rate/depth matching and
reports remain. The flag defaults to 1 in `project.yml`. CI's flag-off build
and symbol check are commented out in `build.yml`, to be restored if App Store
review rejects the hog-mode APIs and two builds must ship. Sandbox success
below is a technical measurement, not an App Store acceptance decision.

## Measurements

Measured 2026-09-15 on this Mac, macOS 27.0, using the Xcode 26 SDK:

| Experiment | Result |
| --- | --- |
| One physical-format write, speakers and BlackHole | Nominal rate read back within the first 5 ms poll; the bounded wait remains 1.5 seconds. |
| BlackHole loopback, mode on | 44.1/16, 48/16, 88.2/24, 96/24 WAV and 96/24 FLAC: zero mismatches over 265,924–766,590 compared frames per file. |
| Fresh mixer's output connection | Defaults to 44.1 kHz even on a 48 kHz device. The output unit resamples, with error up to 1.4e-3. Wiring the master bus at the device's rate removes this. |
| Varispeed at pitch 0 | Error up to 5.4e-6 even at matching sample rates. Removing the node is necessary; a ratio of 1 is not transparent. |
| Sandboxed format and hog writes | Both work without additional entitlements. A non-default speaker device is released after pause and reacquired on resume; the OS releases ownership at process exit. |
| FLAC source depth | 24-bit FLAC exposes ALAC-compatible depth flags (`0x00000003`), read by the same rule. |
| 32-bit integer source through AVAudioFile | 24,641,537 becomes 24,641,536 in float32 decoding. The report refuses Active even if the physical device offers 32-bit integer output. |
| Speaker balance at main volume 1.0 | Left/right balance changes do not change virtual main volume. Balance must be read and watched separately. |

These findings explain the direct node → mixer path, the bit-perfect master-bus rewiring
helper, and the separate rate, channel, depth, gain and ownership report inputs.

### System-output experiment

Hogging the current system output makes coreaudiod move the default elsewhere.
AVAudioEngine's default output unit follows that move despite an explicit
`kAudioOutputUnitProperty_CurrentDevice` binding. In the app this caused a recovery
loop roughly twice a second, five-second engine-start stalls, and audio on the
wrong device after a switch. The mode refused the default for that reason until
the follow was measured precisely.

Measured 2026-09-19, macOS 26.6, RME Fireface 802 as the system default
(`hogfollow.swift` in the vibe-debug skill, plus a poll of the unit and the
default from inside the player queue):

| Observation | Result |
| --- | --- |
| Default move | Already done when the hog write returns; the write itself takes ~207 ms. |
| Output-unit follow | Lands ~50 ms AFTER the default moved, so a unit read taken immediately after the take still names the hogged device and proves nothing. |
| Pinning before the follow | Overwritten by it. The engine then starts against a binding that moves under it. |
| Engine started inside that window | No IO cycle ever arrives: `[AVAudioPlayerNode play]` blocks 5 s in `AVAudioClock awaitIOCycle:`, then the recovery rebuilds. Total resume cost 6 s, versus 0.25 s with the mode off. |
| Waiting for the follow, then re-pinning | Resume settles in 0.36–0.64 s, `formatConfirmed` true, hog owned, playback uninterrupted across repeated toggles, idle-stop releases and device switches. |
| `-[AVAudioEngine prepare]` after the re-pin | **Deadlock.** It `dispatch_sync`s onto the AVAudioIOUnit queue, which is draining the property listener for that re-bind and blocked in CoreAudio (`HALC_ProxyObject::HasProperty`) while the HAL reorganizes around the take. The player queue waits on it and the app hangs. |
| Release | The system default returns to the device by itself; quit restores the format and releases ownership. |

So the rule is not "never hog the default" but "wait for the follow the take
causes, then take the binding back" — `settleOutputUnitAfterHoggingSystemDefaultOnQueue:`,
entered only when the device was the default *and* the unit was bound to it.
While a bit-perfect device is prepared, a listener on the output unit also catches
same-rate default moves that produce no AVAudioEngine configuration notification,
using the normal recovery path.

### Ownership failures

HAL hog writes toggle ownership regardless of the PID value supplied. The helper
reads before writing and checks afterward. The player records the device before
attempting a take, retains it across failed releases, and cannot acquire a second
device over that obligation. Release retries once; persistent failures remain
available to later mode/device/start/idle/termination cleanup. The report reads
actual ownership rather than treating the cleanup slot as proof of a take.

## Verification

Use the [vibe-debug skill](../../.claude/skills/vibe-debug/SKILL.md). Its generator
creates the `rates/` corpus under `Assets/test_audio_files/`; its
[`verify-bit-perfect.swift`](../../.claude/skills/vibe-debug/scripts/verify-bit-perfect.swift)
compares live BlackHole capture against a source after alignment. Real-hardware
loopback requires a unity mixer and BlackHole selected before playback. Speaker
routing and ownership checks use silent playback. Save and restore all changed
HAL properties, and use an isolated app identity for preferences.

The regression set covers:

- Mixed 44.1/48/88.2/96 kHz tracks, seeks, pause/idle/resume, external rate changes,
  and restoration when leaving a device or disabling the mode.
- Mode toggles during an open, a same-device selection that makes a pending mode
  eligible, and same-rate system-output changes during playback and pause.
- Cold-off playback and on/off round trips against the pre-feature graph and idle
  timing, traced for absence of bit-perfect calls and listeners; a selected-device
  fallback while an open is held must restore the normal incoming chain.
- Header lock, tooltip and Settings caption on play/pause/stop, volume, mute and
  balance changes. **Screenshot first after the transition**: other debug verbs
  refresh the pane and can hide a missing production update.
- Exclusive off/on, idle release, failed release, failed acquisition read-back,
  and failed default reads. Inspect actual HAL ownership as well as the report.
- Oracle cleanup on success, early failure, and timeout.
- Host-less format/fold tests, both platform builds and Release analyzers, layout,
  vocabulary, catalog synchronization, and the exclusive-disabled build.

### Review regression checks (2026-09-16)

The five-second live-toggle stall came from starting before the output unit
caught up with a format write. Preparation and restoration now share a bounded
write-and-confirm path: physical format, nominal rate and the bound output unit
must agree. Restoration retains its saved format until that confirmation;
repeated toggles previously lost the original 96 kHz setting and left 48 kHz.
The acceptance matrix includes 12 seek-and-toggle cycles and verifies restoration
after pending opens, failure, mode-off, device changes and quit.

Eight full-tail captures (four WAV rates, FLAC, stop/replay, the same-rate gapless
join and replay after a rate switch) matched exactly. An injected 48 kHz mixer
connection into a 44.1 kHz output exposed a missing report check; confirmation
now requires the graph's rates to agree with the physical output too.

Hardware test launches suppress Now Playing with `--no-now-playing`; media-focus
publication was pulling the user's AirPods off their phone during BlackHole
captures. `VIBE_NOW_PLAYING=1` explicitly enables media-integration testing.

## Remaining limits and release work

- No integer-format USB DAC was attached. Integer format selection is unit-tested;
  live integer-depth negotiation, DAC relock timing, and unplug/replug still need
  that hardware. Built-in speakers provide the live non-default hog test.
- The new bit-perfect/exclusive strings require the normal translation pass before
  release; `make check-translations` is the release gate.
- The everyday FX chain is not promised sample-exact. Bit-perfect routes around
  the FX segment entirely; live setting changes briefly interrupt playback.
- iOS, raw integer IO bypassing AVAudioEngine, DSD/DoP, user-selectable upsampling
  and app volume controls are outside this feature. Bit-perfect and exclusive
  output are remembered per device UID (`Audio/Mac/Devices/CLAUDE.md`).

## API references

The SDK headers are the primary reference: `CoreAudio/AudioHardware.h` for hog
and stereo-pan semantics; `AudioToolbox/AudioHardwareService.h` for virtual main
volume; `CoreAudioTypes/CoreAudioBaseTypes.h` for PCM and ALAC/FLAC depth flags.

## Appendix A — the read-only HAL probe

Compile with `clang -o halprobe halprobe.c -framework CoreAudio -framework CoreFoundation`.
It writes nothing; it is what produced the table above and what Q3 and Q7 read the hog owner
with from outside the app.

```c
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

static void fourcc(UInt32 v, char *o) { o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; o[3]=v; o[4]=0; }
static void printStr(AudioObjectID id, AudioObjectPropertySelector sel, const char *label) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef s = NULL; UInt32 sz = sizeof s; char buf[256] = "(none)";
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &s) == noErr && s) {
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s);
    }
    printf("  %s: %s\n", label, buf);
}
int main(void) {
    AudioObjectPropertyAddress devs = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devs, 0, NULL, &sz);
    AudioDeviceID *ids = malloc(sz); AudioObjectGetPropertyData(kAudioObjectSystemObject, &devs, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioDeviceID); i++) {
        AudioDeviceID d = ids[i];
        AudioObjectPropertyAddress cfg = { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 csz = 0; AudioObjectGetPropertyDataSize(d, &cfg, 0, NULL, &csz);
        AudioBufferList *abl = malloc(csz); UInt32 ch = 0;
        if (AudioObjectGetPropertyData(d, &cfg, 0, NULL, &csz, abl) == noErr)
            for (UInt32 b = 0; b < abl->mNumberBuffers; b++) ch += abl->mBuffers[b].mNumberChannels;
        free(abl);
        if (!ch) continue;
        printf("Device %u (%u output channels)\n", d, ch);
        printStr(d, kAudioObjectPropertyName, "name"); printStr(d, kAudioDevicePropertyDeviceUID, "uid");
        AudioObjectPropertyAddress tt = { kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 t = 0, tsz = sizeof t; char tc[5] = "????";
        if (AudioObjectGetPropertyData(d, &tt, 0, NULL, &tsz, &t) == noErr) fourcc(t, tc);
        AudioObjectPropertyAddress nr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 rate = 0; UInt32 rsz = sizeof rate; AudioObjectGetPropertyData(d, &nr, 0, NULL, &rsz, &rate);
        printf("  transport: %s  nominal rate: %.0f\n", tc, rate);
        AudioObjectPropertyAddress ar = { kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 asz = 0; AudioObjectGetPropertyDataSize(d, &ar, 0, NULL, &asz);
        AudioValueRange *ranges = malloc(asz);
        if (AudioObjectGetPropertyData(d, &ar, 0, NULL, &asz, ranges) == noErr) {
            printf("  available rates:");
            for (UInt32 r = 0; r < asz / sizeof(AudioValueRange); r++) printf(" %.0f", ranges[r].mMinimum);
            printf("\n");
        }
        free(ranges);
        AudioObjectPropertyAddress hm = { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        pid_t hog = -1; UInt32 hsz = sizeof hog; Boolean settable = 0;
        AudioObjectGetPropertyData(d, &hm, 0, NULL, &hsz, &hog); AudioObjectIsPropertySettable(d, &hm, &settable);
        printf("  hog mode: pid=%d settable=%d\n", (int)hog, settable);
        AudioObjectPropertyAddress vmv = { 'vmvc', kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        Float32 vol = -1; UInt32 vsz = sizeof vol;
        if (AudioObjectHasProperty(d, &vmv) && AudioObjectGetPropertyData(d, &vmv, 0, NULL, &vsz, &vol) == noErr)
            printf("  software volume: %.3f\n", vol);
        AudioObjectPropertyAddress vs = { kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        printf("  hardware volume property: %s\n", AudioObjectHasProperty(d, &vs) ? "yes" : "no");
        AudioObjectPropertyAddress st = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 ssz = 0; AudioObjectGetPropertyDataSize(d, &st, 0, NULL, &ssz);
        AudioStreamID *streams = malloc(ssz); AudioObjectGetPropertyData(d, &st, 0, NULL, &ssz, streams);
        for (UInt32 s = 0; s < ssz / sizeof(AudioStreamID); s++) {
            AudioObjectPropertyAddress pf = { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioStreamBasicDescription f = {0}; UInt32 fsz = sizeof f;
            AudioObjectGetPropertyData(streams[s], &pf, 0, NULL, &fsz, &f);
            printf("  stream %u physical: %.0f Hz %s%u %uch\n", streams[s], f.mSampleRate,
                   (f.mFormatFlags & kAudioFormatFlagIsFloat) ? "f" : "i", (unsigned)f.mBitsPerChannel, (unsigned)f.mChannelsPerFrame);
            AudioObjectPropertyAddress apf = { kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            UInt32 apsz = 0; AudioObjectGetPropertyDataSize(streams[s], &apf, 0, NULL, &apsz);
            AudioStreamRangedDescription *fmts = malloc(apsz);
            if (AudioObjectGetPropertyData(streams[s], &apf, 0, NULL, &apsz, fmts) == noErr) {
                printf("    available:");
                for (UInt32 k = 0; k < apsz / sizeof *fmts; k++)
                    printf(" [%.0f %s%u]", fmts[k].mFormat.mSampleRate,
                           (fmts[k].mFormat.mFormatFlags & kAudioFormatFlagIsFloat) ? "f" : "i",
                           (unsigned)fmts[k].mFormat.mBitsPerChannel);
                printf("\n");
            }
            free(fmts);
        }
        free(streams);
    }
    free(ids);
    return 0;
}
```

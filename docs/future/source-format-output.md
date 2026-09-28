# Plan: preserve source PCM through bit-perfect output

**Status: parked (verified 2026-09-27).** Only 32-bit integer and float64 sources would play differently, they are rare in real libraries, and the bit-perfect report already refuses to call them Active (`depthOK`, `OutputFormatRules.h`). The cost is rewriting the bus's sample storage. Two pieces landed on their own: the device-selected Int16 path for lossy files is gone (a lossy file picks the float format, else the widest integer depth, and reaches the bus as float32 like every other file), and the host-less render suite compares wider sources at full width (`CompareWidePCM`), so float32's narrowing of Int32 and float64 samples is counted rather than shared by the reference.

**Revisit** when users bring such files, and only with a digital loopback that captures wider than float32 to prove the result.

## What the change is

Carry the source's decoded PCM representation through the existing voice bus and into CoreAudio wherever the destination permits it; ordinary mixing and FX keep their float32 path. It changes the bus's sample storage and copy operations, the decoder open, and output negotiation. It is not a second player or transport.

## Constraints

- **Decoder output is the boundary.** The production opener, `kProductionFileOpener` in `AudioFileMaterializationCoordinator.m`, calls `AudioFileHandle`'s `initForReading:error:`, whose default is planar float32. `AudioFileHandle` already accepts an explicit format (`initForReading:commonFormat:interleaved:error:`), so the reader needs no replacement: select its format from source metadata inside the existing admitted handle-open run, independent of the current device and mode, before any voice exists. A `processingFormat` of float32 describes the chosen interface, not the codec's arithmetic or a lossy file's original depth.
- **Float32 carries every ≤24-bit integer PCM value exactly**, since its significand is 24 bits; 16-, 20-, and 24-bit sources are already value-exact. It cannot carry every Int32 sample, and float64 narrowed to float32 can lose precision. That gap is the whole feature.
- **A client ASBD proves nothing.** AUHAL may insert a converter between the client and device formats, so setting an Int32 client format does not establish an integer path; read back the stream's virtual and physical formats and measure. [Apple: AUHAL format conversion](https://developer.apple.com/library/archive/technotes/tn2091/_index.html#//apple_ref/doc/uid/DTS10000418-CH1-SUBSECTION6)
- **The comparator and loopback must capture wider than float32, or they pass falsely.** The manual pump reads `floatChannelData`, and `verify-bit-perfect.swift` compares `[[Float]]`; widening only the reference lets the same truncation hit reference and capture alike. The comparator must fail on one deliberately corrupted low bit, and a float32-only BlackHole loopback cannot validate Int32 or float64 output. Without a wider digital loopback, report hardware precision as unverified.
- **Budget: zero new files and zero new types.** One resolved format choice carried through the existing owners: the reader and opener, `AudioVoiceBus`, `AudioPlayer+Pipeline`'s master slicing, `AudioOutputUnit`'s client format, `OutputFormatRules.h`'s negotiation, and the one bit-perfect report. Reuse `AVAudioFormat`/ASBD and `followOutputFormatOnQueue:`'s rebuild and restore rather than adding a format class, a second rebuild sequence, or another output backend.

## Things the design must not lose

- A unity-gain, sole audible voice copies ring spans straight to the output; anything else (Declick edges, fades, several voices, a channel fold, rate conversion) takes the float path and is reported as processed, never as exact.
- The meter and diagnostic capture read a converted copy; they never touch the bytes delivered to the output unit.
- A successor whose format the current ring, client, and device cannot carry exactly takes the settlement and its gap; never narrow precision to keep a splice.

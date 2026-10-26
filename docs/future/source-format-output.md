# Future: preserve source PCM through bit-perfect output

**Status: Not built. Parked.** Only 32-bit integer and float64 sources would play differently. They are rare in real libraries. The bit-perfect report already refuses to call them Active (`depthOK`, from `OutputFormatRules.h`'s `VibePhysicalFormatSatisfies`). The cost is rewriting the bus's sample storage.

**Revisit** when users bring such files, and only with a digital loopback that captures wider than float32 to prove the result.

## What the change is

Carry the source's decoded PCM representation through the existing voice bus and into CoreAudio wherever the destination permits it. Mixing and FX keep their float32 path. It changes the bus's sample storage and copies, the decoder open and output negotiation. It is not a second player or transport.

## Constraints

- **Decoder output is the boundary.** The player's opener (`VibePlayerFileOpener`, `AudioPlayer.m`) calls `initForReading:interleaved:interrupted:error:` with `interleaved:NO`, which reads planar float32. `AudioFileHandle` reads float32 only, so the reader needs a format parameter. Choose the format from source metadata inside the admitted handle-open run, independent of the device and mode, before any voice exists. Keep streaming reads interruptible.
- **Float32 carries every integer sample of 24 bits or fewer exactly**, since its significand is 24 bits. It cannot carry every Int32 sample, and float64 narrowed to float32 can lose precision. That gap is the whole feature.
- **A client ASBD proves nothing.** AUHAL may insert a converter between the client and device formats. Read back the stream's virtual and physical formats, and measure ([Apple: AUHAL format conversion](https://developer.apple.com/library/archive/technotes/tn2091/_index.html#//apple_ref/doc/uid/DTS10000418-CH1-SUBSECTION6)).
- **Proving wider output needs a wider capture.** The render suite's `VibeCompareWidePCM` already counts what float32 loses. `verify-bit-perfect.swift` compares `[[Float]]`, so it and a float32 BlackHole loopback cannot validate Int32 or float64 output. Without a wider digital loopback, report hardware precision as unverified.
- **Budget: zero new files and zero new types.** Carry one resolved format choice through the existing owners: the reader and opener, `AudioVoiceBus`, `AudioMasterBus`'s slicing, `AudioOutputUnit`'s client format, `OutputFormatRules.h`'s negotiation and the bit-perfect report. Reuse `AVAudioFormat` and `followOutputFormatOnQueue:`'s rebuild and restore.

## What the design must not lose

- Only a unity-gain, sole audible voice copies ring spans straight to the output. Declick edges, fades, several voices, a channel fold or rate conversion take the float path and are reported as processed, never exact.
- The meter and diagnostic capture read a converted copy. They never touch the bytes delivered to the output unit.
- A successor whose format the current ring, client and device cannot carry exactly takes the settlement and its gap. Never narrow precision to keep a splice.

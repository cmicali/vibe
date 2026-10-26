# Open issues

Bugs seen in testing that are not fixed or not explained.

## iPad simulator aborts in RemoteIO stop

**What fails.** The iOS app aborted with SIGABRT inside `AURemoteIO::Stop` after an RPC timeout. The output queue was in that stop. The player queue waited on it from `releaseIdleOutputUnitOnQueue`. Main waited on the player queue for a debug consistency snapshot, so the debug channel stopped answering.

**How it happened.** It happened once, on the iPad simulator, during a long real-output soak. A macOS exclusive mixed-rate run was changing the host's audio devices at the same time. Every simulator shares the host's CoreAudio.

**What is known.**
- It has not been reproduced. These all passed: the iPad alone, the iPad while the host default output flipped, the iPad during a Mac exclusive run, and a command replay of the crash's last operations.
- A standalone RemoteIO probe with no Vibe code survived hog ownership, rate writes and format changes on the host.
- Audio had stopped advancing almost three minutes before the abort. The soak's oracle checked only `state == playing`, so it missed this. A real-output soak must check that the position advances, and sample the process when it stops.
- The stop-before-deactivation wait is required (vibe-libs' `audio/Player/iOS/AudioPlayer+Recovery.m`, its `TRAP`). Removing it, or putting a timeout on Vibe's waiter, would not cancel the RemoteIO RPC in flight.
- Next step: reproduce first. Replay the whole preceding host sequence, including the Mac device-fault and aggregate work. Sample frame progress continuously and take stacks before the timeout. Physical devices were never tested.

## Mac output hangs in AudioUnitInitialize

**What fails.** During the device-fault check of `verify-bit-perfect.swift`, the output queue blocked for more than six minutes in `AudioUnitInitialize`, in `HALC_ProxyIOContext::_TellServerAboutStreamUsage`. It hung on the first volume-read fault case on VibeBlackHole.

**What is known.**
- One cause is fixed. HAL delivers running and overload notifications on its IO thread. The beta event logger read a HAL property inside them, which deadlocked the stop (the HAL notification `TRAP` in vibe-libs' `audio/OutputDevices/AGENTS.md`). The same fault case reproduced 13 to 28 second stalls, and the fix removed them.
- The original hang was a wait on the server RPC, not that cycle. The host had already logged IO-thread start errors before the app launched. The cause is not proven.
- With the fix, the whole device-fault check passes, the volume-read fault and the aggregate case included.
- If it recurs: sample the app before recovery, and keep the bundle UUID, the dSYM and the client and server logs. Keep simulator audio and other HAL drivers out of the run. Do not wrap a blocked HAL call in a timeout that frees state it still uses.

## Known TSan noise

With TSan on, a few unit tests that use dispatch timers and blocks report races (vibe-libs' `DownloadAllocatedSizeSource` and `MetadataParseCoordinatorTests`). Standalone Foundation and libdispatch programs with no Vibe code show the same warnings. Do not change synchronization only to silence them. Check the standalone repro on the current toolchain first.

# Bug: a running stage-1 materialization has no deadline

Found while reviewing the dataless-probe fix (`fabbc5da`; its plan is
`git show fabbc5da:docs/done/fix-dataless-probe-on-state-queue.md`). **Partly fixed**: a local
run no longer holds a lane slot; the rest is open.

The initial-classification scheduler caps concurrent and pending probes; it cannot cancel a
probe already blocked in `stat(2)`. A delayed/readmitted dataless claim is different again: its
refresh runs after lane reservation and can hold that lane until the probe returns. Both cases
are recorded in `docs/file-loading-spec.md` B10.

This bug tracks the next stage. Once a claim enters `Running`, pending admission expiry no longer
reaches it, and caller cancellation asks the operation to stop but cannot make a blocked call
return: metadata and artwork have no deadline which guarantees that cancellation happens.

**Fixed:** a local run used to count against its lane, so a coordinated read stalled on SMB,
NFS, or a sleeping external disk held the one-wide background lane and every later dataless claim
expired behind it. Only a dataless run holds a slot now (`holdsLane`, pinned by
`testAStalledLocalRunLeavesTheLaneToTransfers`), which bounds transfers and nothing else.

**Open:** a *dataless* run whose provider never answers still holds its slot until it does, and a
stalled local read still keeps its worker thread. Both need what a coordinator timeout would need:
an explicit policy for legitimately slow volumes and providers, caller-specific deadlines, and
what metadata scanning should do after expiry. No thread blocked in a system call can be
reclaimed in-process, so a timeout frees the slot, never the thread. Do not add one without
resolving those choices.

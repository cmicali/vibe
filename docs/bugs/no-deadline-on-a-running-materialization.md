# Bug: a running stage-1 materialization has no deadline

Found while reviewing
[the dataless-probe fix](../done/fix-dataless-probe-on-state-queue.md). **Not fixed.**

The initial-classification scheduler caps concurrent and pending probes; it cannot cancel a
probe already blocked in `stat(2)`. A delayed/readmitted dataless claim is different again: its
refresh runs after lane reservation and can hold that lane until the probe returns. Both cases
are recorded in `docs/file-loading-spec.md` B10.

This bug tracks the next stage. Once a claim enters `Running`, pending admission expiry no longer
reaches it. A local file bypasses transfer capacity when admitted but still increments the lane's
running count, so a coordinated read stalled on SMB, NFS, or a sleeping external disk can prevent
later dataless work from entering that lane. Caller cancellation asks the operation to stop, but
metadata and artwork have no deadline which guarantees that cancellation happens.

A fix needs an explicit policy for legitimate slow volumes, caller-specific deadlines, and what
metadata scanning should do after expiry. Do not add a coordinator timeout without resolving
those choices. No test pins the current undesirable behavior; reproducing it needs a slow volume
or a materialization-operation fake that can stall independently of classification.

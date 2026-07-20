#!/bin/bash
# Put the running app into a real, indefinitely-held Loading state — the
# thing no local file can produce — for testing the shimmer, loading-state
# header, load-timeout error, and anything gated on didBeginLoading:.
#
# Opens a named pipe: AVAudioFile's open blocks reading it forever (no
# writer), exactly like an undownloaded iCloud/Dropbox placeholder. The pipe
# lives in the app container's tmp (the sandbox can't read arbitrary paths)
# and is fed via `--debug-cmd open`. Timeline after this runs: loading
# shimmer at 0.5s, inline "Load timed out" error at 20s. The app's blocked
# open worker is stranded until the timeout — same accepted tradeoff as a
# real hung cloud file.
#
# Usage: slow-open.sh            # start a slow open (replaces any previous pipe)
#        slow-open.sh cleanup    # unblock any pending open (it fails instantly
#                                # into the inline error — unlinking alone would
#                                # leave it hanging until the 20s timeout) and
#                                # remove the pipe
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
FIFO="$HOME/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/slow-load.wav"

if [ "${1:-}" = "cleanup" ]; then
    # Nonblocking write: if the app's open is blocked reading the pipe this
    # feeds it one junk byte + EOF (open fails immediately); with no reader
    # it raises ENXIO and is skipped. A plain `echo >` would itself block.
    python3 -c 'import os,sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, b"x"); os.close(fd)
except OSError: pass' "$FIFO" 2>/dev/null || true
    rm -f "$FIFO"
    echo '{"ok":true,"cleaned":true}'
    exit 0
fi

[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }
pgrep -x Vibe >/dev/null || { echo "no running Vibe — launch.sh first" >&2; exit 1; }

rm -f "$FIFO"
mkfifo "$FIFO"
"$V" --debug-cmd open "$FIFO"

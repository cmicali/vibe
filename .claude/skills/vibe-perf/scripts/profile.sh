#!/bin/bash
# Samples one VibePerf benchmark while it loops, and prints the heaviest
# frames: where a benchmark's time goes, without Instruments.
#
# Usage: profile.sh <benchmark regex> [seconds=6] [binary]
# Output: the call tree in build/perf/profile-<name>.txt, the top of it on stdout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
FILTER="$1"
SECONDS_TO_SAMPLE="${2:-6}"
BIN="${3:-$ROOT/build/PerfDerivedData/Build/Products/Release/VibePerf}"
OUT="$ROOT/build/perf/profile-$(echo "$FILTER" | tr -c 'A-Za-z0-9.-' '_').txt"
mkdir -p "$ROOT/build/perf"

"$BIN" --corpus "$ROOT/build/bench/corpus" --filter "$FILTER" --loop $((SECONDS_TO_SAMPLE + 3)) >/dev/null &
PID=$!
# Past prepare (which may decode a fixture) before sampling.
sleep 2
sample "$PID" "$SECONDS_TO_SAMPLE" 1 -mayDie -file "$OUT" >/dev/null 2>&1 || true
wait "$PID" || true
# The "Sort by top of stack" section: self time per function.
awk '/Sort by top of stack/{on=1} on' "$OUT" | head -40

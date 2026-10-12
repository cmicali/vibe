#!/bin/bash
# Measures Apple's Varispeed, the pitch fader's converter before Vibe's own,
# against r8brain and a prototype of Vibe's windowed-sinc converter. The
# findings are in docs/audio-quality.md, under "The pitch fader".
#
# Usage: scripts/varispeed-quality/run.sh quality apple|r8brain|custom|custom-float ...
#        scripts/varispeed-quality/run.sh drag
#        scripts/varispeed-quality/run.sh cpu
#
# quality prints each engine's gain, distortion + noise, quiet-tone floor,
# twenty-tone residual and false tones at fader settings from -16% to +16%.
# drag measures side tones while the fader moves. cpu times all four engines.
# VS_T, VS_FC, VS_BETA and VS_P override the custom kernel (measure.c).
#
# Output: build/varispeed-quality/measure, rebuilt when its sources change.
# r8brain builds with project.yml's flags for it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/varispeed-quality"
R8="$ROOT/Vibe/ThirdParty/r8brain"
OUT="$ROOT/build/varispeed-quality"
R8FLAGS=(-O3 -DR8BSRC_DECL= -DR8B_PFFFT_DOUBLE=1 -DPFFFT_ENABLE_NEON=1 -w)

mkdir -p "$OUT"
if [ ! -f "$OUT/r8bsrc.o" ] || [ -n "$(find "$R8" -newer "$OUT/r8bsrc.o" -print -quit)" ]; then
    clang++ -std=c++17 "${R8FLAGS[@]}" -I"$R8" -c "$R8/DLL/r8bsrc.cpp" -o "$OUT/r8bsrc.o"
    clang "${R8FLAGS[@]}" -I"$R8" -c "$R8/fft/pffft_double.c" -o "$OUT/pffft_double.o"
fi
if [ ! -x "$OUT/measure" ] || [ "$HERE/measure.c" -nt "$OUT/measure" ] || [ "$OUT/r8bsrc.o" -nt "$OUT/measure" ]; then
    clang -O3 -c "$HERE/measure.c" -o "$OUT/measure.o"
    clang++ "$OUT/measure.o" "$OUT/r8bsrc.o" "$OUT/pffft_double.o" \
        -framework AudioToolbox -framework Accelerate -framework CoreFoundation -o "$OUT/measure"
fi
exec "$OUT/measure" "$@"

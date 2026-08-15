#!/bin/bash
# Enforces the mechanical half of CLAUDE.md's Vocabulary section. Prose rules
# there cover judgment; these three cover what a grep can settle, so they can
# be reviewed by CI instead of by memory.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0

fail() {
    echo "✘ $1" >&2
    status=1
}

# A generation counter says what it guards. A bare one reads as something
# special when it is just one of several in the same file.
bare=$(grep -rn '\b_generation\b' Vibe Tests --include='*.m' --include='*.mm' --include='*.h' \
        2>/dev/null | grep -v ThirdParty || true)
if [ -n "$bare" ]; then
    fail "bare '_generation' — spell it <protectedThing>Generation:"
    echo "$bare" >&2
fi

# 'claim' is single-flight ownership only; OS-level role registration is
# 'registration' (DefaultAppRegistration).
claims=$(grep -rn 'DefaultAppClaim' Vibe Tests 2>/dev/null | grep -v ThirdParty || true)
if [ -n "$claims" ]; then
    fail "'DefaultAppClaim' — OS role registration is not a single-flight claim:"
    echo "$claims" >&2
fi

# A header-only file of static inlines is a testable seam, and the suffix says
# which kind: Rules returns a decision, Math returns a number. Everything on the
# allowlist is a header-only file that is NOT a seam — types, macros, ivar
# declarations, the string registry.
allowlist="AudioPlayerInternal.h HelperMacros.h MusicalKey.h PlaybackIntent.h VibeStrings.h"
while IFS= read -r header; do
    grep -q 'static inline' "$header" || continue
    base="${header%.h}"
    { [ -f "$base.m" ] || [ -f "$base.mm" ]; } && continue
    name=$(basename "$header")
    case " $allowlist " in *" $name "*) continue ;; esac
    case "$name" in *Rules.h|*Math.h) continue ;; esac
    fail "$header — a header-only static-inline seam must be *Rules.h (returns a decision) or *Math.h (returns a number)"
done < <(find Vibe -name '*.h' ! -path '*/ThirdParty/*')

if [ "$status" -eq 0 ]; then
    echo "✅ vocabulary OK"
fi
exit "$status"

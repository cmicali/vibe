#!/bin/bash
# Enforces the mechanical half of CLAUDE.md's Vocabulary section. Prose rules
# there cover judgment; the rules below cover what a grep can settle, so they
# can be reviewed by CI instead of by memory. Keep their count in step with the
# numbered list in the root CLAUDE.md, which is written against this file.
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

# Debug surface belongs in Vibe/Debug/, as a declaration-only category — a
# shipping header should not carry a conditional block about a tool that does
# not ship. There are NO exceptions, and there is no allowlist here on purpose:
# the two that used to be here were both storage a category cannot add, and
# both had a better answer. A debug-only property ships as a pointer
# (MainPlayerControllerInternal.h's conversionUndoRedoSettledHandler);
# debug-only state belongs to a debug-only OBJECT the shipping class holds
# (VibeManualRenderPump). Reach for those before adding a name below.
#
# Anchored to the directive, not the string: a header is allowed to *mention*
# the conditional in a comment explaining why it does not use one.
stray_debug=$(grep -rlnE '^[[:space:]]*#if[[:space:]]+DEBUG' Vibe --include='*.h' 2>/dev/null \
        | grep -v ThirdParty | grep -v '^Vibe/Debug/' || true)
if [ -n "$stray_debug" ]; then
    fail "#if DEBUG in a shipping header — declare it as a category under Vibe/Debug/ instead (Mac/Introspection/ or iOS/):"
    echo "$stray_debug" >&2
fi

# One spelling for the trap marker, so grep finds every one of them.
bad_trap=$(grep -rn 'TRAP' Vibe --include='*.h' --include='*.m' --include='*.mm' 2>/dev/null \
        | grep -v ThirdParty | grep -v 'TRAP:' || true)
if [ -n "$bad_trap" ]; then
    fail "trap marker must be spelled 'TRAP:':"
    echo "$bad_trap" >&2
fi

# A condition the code must keep true is a 'guarantee'. 'invariant' is the
# synonym that keeps coming back, and a second word for it is what stops
# `grep -rn guarantee` from finding every one. No allowlist: the two prior
# non-synonym uses ("invariant scaffolding", "shift-invariant") both read
# better as plain English, so neither earns an exception here. Covers the
# directory docs too, since they carry as many of these conditions as the code.
bad_invariant=$(grep -rni 'invariant' Vibe Tests \
        --include='*.h' --include='*.m' --include='*.mm' --include='*.md' 2>/dev/null \
        | grep -v ThirdParty || true)
if [ -n "$bad_invariant" ]; then
    fail "a condition the code must keep true is a 'guarantee', never an 'invariant':"
    echo "$bad_invariant" >&2
fi

if [ "$status" -eq 0 ]; then
    echo "✅ vocabulary OK"
fi
exit "$status"

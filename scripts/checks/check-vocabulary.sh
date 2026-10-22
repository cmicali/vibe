#!/bin/bash
# Enforces the mechanical half of the root AGENTS.md's Vocabulary section,
# the doc line limit, and the absence of merge conflict markers.
set -uo pipefail
cd "$(dirname "$0")/../.."

status=0

fail() {
    echo "✘ $1" >&2
    status=1
}

# 1. A generation counter says what it guards.
bare=$(grep -rn '\b_generation\b' Vibe Tests --include='*.m' --include='*.mm' --include='*.h' \
        2>/dev/null | grep -v ThirdParty || true)
if [ -n "$bare" ]; then
    fail "bare '_generation' — spell it <protectedThing>Generation:"
    echo "$bare" >&2
fi

# 2. 'claim' is single-flight ownership only; OS role registration is
# 'registration' (DefaultAppRegistration).
claims=$(grep -rn 'DefaultAppClaim' Vibe Tests 2>/dev/null | grep -v ThirdParty || true)
if [ -n "$claims" ]; then
    fail "'DefaultAppClaim' — OS role registration is not a single-flight claim:"
    echo "$claims" >&2
fi

# 3. A header-only static-inline file is a seam: *Rules.h returns a decision,
# *Math.h a number. The allowlist is header-only files that are NOT seams.
allowlist="AudioMasterBusInternal.h AudioPlayerInternal.h AudioVoiceBusInternal.h PlaybackIntent.h VibeStrings.h WaveformAccessibility.h"
while IFS= read -r header; do
    grep -q 'static inline' "$header" || continue
    base="${header%.h}"
    { [ -f "$base.m" ] || [ -f "$base.mm" ]; } && continue
    name=$(basename "$header")
    case " $allowlist " in *" $name "*) continue ;; esac
    case "$name" in *Rules.h|*Math.h) continue ;; esac
    fail "$header — a header-only static-inline seam must be *Rules.h (returns a decision) or *Math.h (returns a number)"
done < <(find Vibe -name '*.h' ! -path '*/ThirdParty/*')

# 4. Debug surface is declared in a +Debug category header under Vibe/Debug/,
# with no allowlist. Storage a category cannot add has three answers: a
# debug-only property ships as a pointer (MainPlayerControllerInternal.h's
# conversionUndoRedoSettledHandler), debug-only state lives in a debug-only
# object the shipping class holds (VibeManualRenderPump), and a debug-only
# field a seam reads is declared unconditionally in the class's private header,
# marked as debug-only. Anchored to the directive, so a comment may mention it.
stray_debug=$(grep -rlnE '^[[:space:]]*#if[[:space:]]+DEBUG' Vibe --include='*.h' 2>/dev/null \
        | grep -v ThirdParty | grep -v '^Vibe/Debug/' || true)
if [ -n "$stray_debug" ]; then
    fail "#if DEBUG in a shipping header — declare it as a category under Vibe/Debug/ instead (Seams/, Mac/Seams/ or iOS/Seams/):"
    echo "$stray_debug" >&2
fi

# 5. One spelling for the trap marker, so grep finds every one.
bad_trap=$(grep -rn 'TRAP' Vibe Tests --include='*.h' --include='*.m' --include='*.mm' 2>/dev/null \
        | grep -v ThirdParty | grep -v 'TRAP:' || true)
if [ -n "$bad_trap" ]; then
    fail "trap marker must be spelled 'TRAP:':"
    echo "$bad_trap" >&2
fi

# 6. A condition the code must keep true is a 'guarantee', so one grep finds
# them all. No allowlist, and the directory docs are covered too.
bad_invariant=$(grep -rni 'invariant' Vibe Tests \
        --include='*.h' --include='*.m' --include='*.mm' --include='*.md' 2>/dev/null \
        | grep -v ThirdParty || true)
if [ -n "$bad_invariant" ]; then
    fail "a condition the code must keep true is a 'guarantee', never an 'invariant':"
    echo "$bad_invariant" >&2
fi

# 7. No doc line longer than the limit. Covers every AGENTS.md, every docs/
# page and every skill page, tracked or new.
max_doc_line=1500
long_lines=$(git ls-files --cached --others --exclude-standard \
        'AGENTS.md' '*/AGENTS.md' 'docs/*.md' '.claude/skills/*.md' \
        | xargs awk -v max="$max_doc_line" 'length > max { print FILENAME ":" FNR ": " length " characters" }')
if [ -n "$long_lines" ]; then
    fail "doc line over $max_doc_line characters — split the paragraph or make it a list:"
    echo "$long_lines" >&2
fi

# 8. No merge conflict marker in a text file, tracked or new. A marker is
# exactly seven <, = or > at a line's start, then a space or the line's end.
# A longer Markdown or RST underline of = is not one. Vendored code is other
# authors', and vibe-libs/ is a submodule that runs its own check.
markers=$(git ls-files -z --cached --others --exclude-standard \
        | grep -zv '^Vibe/ThirdParty/' \
        | xargs -0 grep -InE '^(<{7}|={7}|>{7})( |$)' 2>/dev/null || true)
if [ -n "$markers" ]; then
    fail "merge conflict marker — resolve the conflict:"
    echo "$markers" >&2
fi

if [ "$status" -eq 0 ]; then
    echo "✅ vocabulary OK"
fi
exit "$status"

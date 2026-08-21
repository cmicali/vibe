#!/bin/bash
# Enforces the layout rule stated in CLAUDE.md: every directory directly under
# Vibe/ except Mac/, iOS/ and ThirdParty/ is a shared subsystem listed in both
# targets, and within any subsystem Mac/ and iOS/ are the only platform
# markers. Prose annotations drift; this does not.
#
# Four assertions, all mechanical. The first three read project.yml, which
# settles which SOURCES compile; the fourth reads the imports, which settles
# which HEADERS may be named — Xcode's project-wide headermap resolves any
# header in the project from any target, so target membership does not.
#   1. every exclude is on the whitelist — no feature-named exclude anywhere;
#   2. no Vibe path names the other platform, and every shared entry carries
#      its platform exclude;
#   3. every top-level directory on disk is a source path in both targets;
#   4. no source outside a platform's tree imports a header only that tree
#      has, unguarded.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0

fail() {
    echo "✘ $1" >&2
    status=1
}

# One record per source entry: "<target>\t<path>\t<comma-separated excludes>",
# plus an "<target>\tINFO\t<Info.plist path>" record per target.
records=$(awk '
function flush() {
    if (target != "" && path != "") printf "%s\t%s\t%s\n", target, path, excl
    path = ""; excl = ""; inexcl = 0
}
/^targets:/            { intargets = 1; next }
!intargets             { next }
/^[^ ]/                { flush(); intargets = 0; next }
/^  [A-Za-z][A-Za-z0-9_]*:[ \t]*$/ {
    flush(); target = $1; sub(/:$/, "", target); insources = 0; next
}
/^    info:[ \t]*$/    { flush(); insources = 0; ininfo = 1; next }
ininfo && /^      path:/ {
    p = $0; sub(/^[ \t]*path:[ \t]*/, "", p); sub(/[ \t]*#.*$/, "", p); gsub(/"/, "", p)
    printf "%s\tINFO\t%s\n", target, p; ininfo = 0; next
}
/^    sources:[ \t]*$/ { flush(); insources = 1; next }
/^    [A-Za-z]/        { flush(); insources = 0; ininfo = 0 }
!insources             { next }
/^      - path:/ {
    flush()
    path = $0; sub(/^[ \t]*-[ \t]*path:[ \t]*/, "", path)
    sub(/[ \t]*#.*$/, "", path); gsub(/"/, "", path)
    next
}
/^        excludes:[ \t]*\[/ {
    e = $0; sub(/^[^[]*\[/, "", e); sub(/\].*$/, "", e)
    gsub(/[" \t]/, "", e); excl = e; inexcl = 0; next
}
/^        excludes:[ \t]*$/ { inexcl = 1; next }
/^        [A-Za-z]/         { inexcl = 0; next }
inexcl && /^          - / {
    e = $0; sub(/^[ \t]*-[ \t]*/, "", e); sub(/[ \t]*#.*$/, "", e); gsub(/[" \t]/, "", e)
    excl = (excl == "") ? e : excl "," e
    next
}
END { flush() }
' project.yml)

# The two app targets only; VibeTests names individual files by design.
targets="Vibe VibeiOS"

# Every exclude a source entry may carry. Anything else — a feature-named
# exclude — means the tree stopped being the membership rule.
allowed_always='**/.DS_Store **/*.md Mac/** iOS/**'
# The two PIN caches are exclude-and-readd entries, not membership decisions:
# each is re-added immediately below its exclusion with per-file compilerFlags
# (ARC exceptions, and the NumberObjectConversion analyzer checker off for
# vendored style the repo does not restyle).
allowed_thirdparty='**/*.xcprivacy **/*.txt **/LICENSE.MPL **/PINDiskCache.m **/PINMemoryCache.m'

info_dir_for() {
    local t="$1" p
    p=$(echo "$records" | awk -F'\t' -v t="$t" '$1 == t && $2 == "INFO" { print $3 }')
    [ -n "$p" ] && dirname "$p"
}

paths_for() {
    echo "$records" | awk -F'\t' -v t="$1" '$1 == t && $2 != "INFO" { print $2 }'
}

excludes_for() {
    echo "$records" | awk -F'\t' -v t="$1" -v p="$2" '$1 == t && $2 == p { print $3 }'
}

has_word() {   # has_word <needle> <space-separated haystack>
    case " $2 " in *" $1 "*) return 0 ;; esac
    return 1
}

# 1. Exclude whitelist.
for t in $targets; do
    shell_dir=$(info_dir_for "$t")
    while IFS=$'\t' read -r target path excl; do
        [ "$target" = "$t" ] || continue
        [ "$path" = "INFO" ] && continue
        allowed="$allowed_always"
        case "$path" in *ThirdParty*) allowed="$allowed $allowed_thirdparty" ;; esac
        [ "$path" = "$shell_dir" ] && allowed="$allowed **/Info.plist"
        IFS=',' read -r -a items <<< "$excl"
        for e in "${items[@]:-}"; do
            [ -z "$e" ] && continue
            has_word "$e" "$allowed" && continue
            fail "$t: '$path' excludes '$e' — only $allowed are allowed; the directory is the membership rule"
        done
    done <<< "$records"
done

# 2. Platform-word membership: a path says which target compiles it, and every
#    shared entry excludes the other platform's half whether or not it exists yet.
vibe_paths=$(paths_for Vibe)
ios_paths=$(paths_for VibeiOS)

while IFS= read -r p; do
    case "$p" in */iOS|*/iOS/*) fail "Vibe: source path '$p' names iOS — it would compile into the macOS app" ;; esac
done <<< "$vibe_paths"
while IFS= read -r p; do
    case "$p" in */Mac|*/Mac/*) fail "VibeiOS: source path '$p' names Mac — it would compile into the iOS app" ;; esac
done <<< "$ios_paths"

shared=$(comm -12 <(echo "$vibe_paths" | sort) <(echo "$ios_paths" | sort) | grep '^Vibe/[^/]*$' || true)
while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in *ThirdParty*) continue ;; esac
    has_word 'iOS/**' "$(excludes_for Vibe "$p" | tr ',' ' ')" \
        || fail "Vibe: shared entry '$p' must exclude 'iOS/**'"
    has_word 'Mac/**' "$(excludes_for VibeiOS "$p" | tr ',' ' ')" \
        || fail "VibeiOS: shared entry '$p' must exclude 'Mac/**'"
done <<< "$shared"

# 3. Top-level coverage. A NEW DIRECTORY NEEDS A NEW ENTRY — nothing globs it in.
for d in Vibe/*/; do
    d="${d%/}"
    case "$d" in Vibe/Mac|Vibe/iOS|Vibe/ThirdParty) continue ;; esac
    has_word "$d" "$(echo "$vibe_paths" | tr '\n' ' ')" \
        || fail "Vibe: '$d' exists on disk but is not a source path — every shared subsystem is in both targets"
    has_word "$d" "$(echo "$ios_paths" | tr '\n' ' ')" \
        || fail "VibeiOS: '$d' exists on disk but is not a source path — every shared subsystem is in both targets"
done
#    Vibe/Mac/ is one entry per piece, for the same reason the top level is:
#    nothing globs a new one in, so a directory nobody named compiles into
#    nothing at all. Deeper nesting needs no entry of its own — each piece's
#    path is recursive. Vibe/iOS is a single recursive entry by design, so it
#    has no equivalent check.
mac_children=0
for d in Vibe/Mac/*/; do
    d="${d%/}"
    mac_children=$((mac_children + 1))
    has_word "$d" "$(echo "$vibe_paths" | tr '\n' ' ')" \
        || fail "Vibe: '$d' exists on disk but is not a source path — Vibe/Mac/ is one entry per piece"
done
[ "$mac_children" -gt 0 ] \
    || fail "Vibe: nothing under Vibe/Mac/ — the macOS app shell lives there"
echo "$ios_paths" | grep -q '^Vibe/iOS' \
    || fail "VibeiOS: no source path under Vibe/iOS — the iOS app shell lives there"

# 4. Imports. Assertions 1-3 settle which sources compile; nothing there stops a
#    shared file from NAMING a header the other target never compiles, and it
#    builds anyway — Xcode's Vibe-project-headers.hmap maps every header in the
#    project by basename, whatever the target. A constant- or static-inline-only
#    header does not even fail to link. So the basename is the key here too.
basenames_under() {   # basenames_under <Mac|iOS>
    find Vibe -name '*.h' -path "*/$1/*" ! -path '*/ThirdParty/*' -exec basename {} \; | sort -u
}
basenames_outside() {
    find Vibe -name '*.h' ! -path "*/$1/*" ! -path '*/ThirdParty/*' -exec basename {} \; | sort -u
}

for platform in Mac iOS; do
    # Only names with no home outside that tree: a header duplicated on both
    # sides (NSView+DarkMode / UIView+DarkMode are separate names, but the rule
    # must not assume that) resolves legitimately either way.
    exclusive=$(comm -23 <(basenames_under "$platform") <(basenames_outside "$platform"))
    [ -n "$exclusive" ] || continue
    names_file=$(mktemp)
    printf '%s\n' "$exclusive" > "$names_file"
    # TARGET_OS_OSX is the one sanctioned reach across, in either direction
    # (`#if TARGET_OS_OSX` on the mac side, `#if !TARGET_OS_OSX` on the iOS
    # side), so one pattern covers both. An #if that opens a guard is tracked by
    # depth, so a nested #if inside it does not end it early.
    hits=$(find Vibe ! -path "*/$platform/*" ! -path '*/ThirdParty/*' \
                \( -name '*.m' -o -name '*.mm' -o -name '*.h' \) -print0 \
        | xargs -0 -I{} awk -v names="$names_file" -v file="{}" '
            BEGIN { while ((getline n < names) > 0) if (n != "") want[n] = 1 }
            /^[ \t]*#[ \t]*(if|ifdef|ifndef)/ {
                depth++; if ($0 ~ /TARGET_OS_OSX/ && guarded == 0) guarded = depth; next
            }
            /^[ \t]*#[ \t]*endif/ { if (guarded == depth) guarded = 0; depth--; next }
            guarded { next }
            /^[ \t]*#[ \t]*import[ \t]*"/ {
                h = $0; sub(/^[^"]*"/, "", h); sub(/".*$/, "", h); sub(/^.*\//, "", h)
                if (h in want) print file ":" FNR ": " h
            }' {})
    rm -f "$names_file"
    if [ -n "$hits" ]; then
        fail "a source outside Vibe/**/$platform/ imports a header only that tree has, unguarded — wrap it in #if TARGET_OS_OSX or move the header:"
        echo "$hits" >&2
    fi
done

if [ "$status" -eq 0 ]; then
    echo "✅ layout OK"
fi
exit "$status"

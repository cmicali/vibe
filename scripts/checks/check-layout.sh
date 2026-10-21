#!/bin/bash
# Enforces the layout rule stated in AGENTS.md: every directory directly under
# Vibe/ except Mac/, iOS/ and ThirdParty/ is a shared subsystem listed in both
# targets, and within any subsystem Mac/ and iOS/ are the only platform
# markers.
#
# Seven assertions. The first three read project.yml, which settles which
# SOURCES compile; the fourth reads the imports, which settles which HEADERS may
# be named, since Xcode's project-wide headermap resolves any header from any
# target; the fifth keeps the agent instructions loadable; the sixth keeps a
# test target's debug seams whole; the seventh keeps the vibe-libs submodule
# present and reached only by header name.
#   1. every exclude is on the whitelist — no feature-named exclude anywhere;
#   2. no Vibe path names the other platform, and every shared entry carries
#      its platform exclude;
#   3. every top-level directory on disk is a source path in both targets;
#   4. no source outside a platform's tree imports a header only that tree
#      has, unguarded;
#   5. no CLAUDE.md or CLAUDE.local.md in the tree or above it;
#   6. every +Debug seam header a test target reaches through its imports has
#      its .m in that target, when the seam has one and the target compiles
#      the class. A selector resolves at run time, so neither the compiler
#      nor the linker catches the gap;
#   7. vibe-libs/ is checked out, and no file imports one of its headers by path.
set -uo pipefail
cd "$(dirname "$0")/../.."

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
#    Vibe/Mac/ is one entry per piece, so a piece nobody named compiles into
#    nothing. Vibe/iOS is a single recursive entry, so it needs no such check.
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

# 4. Imports. A shared file NAMING a header the other target never compiles
#    still builds, because the headermap maps every header by basename, and a
#    constant- or static-inline-only header does not even fail to link. So the
#    basename is the key. A vibe-libs piece's Mac/ and iOS/ halves count as
#    that platform's tree, since the app targets compile them in.
basenames_under() {   # basenames_under <Mac|iOS>
    find Vibe vibe-libs -name '*.h' -path "*/$1/*" ! -path '*/ThirdParty/*' ! -path '*/third_party/*' \
        ! -path 'vibe-libs/build/*' -exec basename {} \; | sort -u
}
basenames_outside() {
    find Vibe vibe-libs -name '*.h' ! -path "*/$1/*" ! -path '*/ThirdParty/*' ! -path '*/third_party/*' \
        ! -path 'vibe-libs/build/*' -exec basename {} \; | sort -u
}

for platform in Mac iOS; do
    # Only names with no home outside that tree: a basename present on both
    # sides resolves legitimately either way.
    exclusive=$(comm -23 <(basenames_under "$platform") <(basenames_outside "$platform"))
    [ -n "$exclusive" ] || continue
    names_file=$(mktemp)
    printf '%s\n' "$exclusive" > "$names_file"
    # TARGET_OS_OSX (either polarity) is the one sanctioned reach across. The
    # guard is tracked by depth so a nested #if does not end it early.
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
        fail "a source outside Vibe/**/$platform/ imports a header only the $platform/ trees have, unguarded — wrap it in #if TARGET_OS_OSX or move the header:"
        echo "$hits" >&2
    fi
done

# 5. The instructions are AGENTS.md. TRAP: one CLAUDE.md, .claude/CLAUDE.md or
#    CLAUDE.local.md in the tree or a directory above it — /init writes one —
#    makes Claude Code read that file alone and skip every AGENTS.md, silently.
#    The worktrees hold other branches' checkouts; ~/.claude/CLAUDE.md is the
#    user file, which does not count.
strays=$(find . -path ./.git -prune -o -path ./build -prune -o -path ./.claude/worktrees -prune \
              -o \( -name CLAUDE.md -o -name CLAUDE.local.md \) -print)
dir=$(cd .. && pwd)
while :; do
    for f in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
        [ "$dir/$f" = "$HOME/.claude/CLAUDE.md" ] && continue
        [ -e "$dir/$f" ] && strays="$strays"$'\n'"$dir/$f"
    done
    [ "$dir" = / ] && break
    dir=$(dirname "$dir")
done
strays=$(echo "$strays" | sed '/^$/d')
if [ -n "$strays" ]; then
    fail "agent instructions are AGENTS.md; each file below makes Claude Code skip every AGENTS.md — rename its content into the AGENTS.md beside it:"
    echo "$strays" >&2
fi

# 6. Seams. A test target that compiles a seam, or a test that imports one,
#    reaches other seam headers through imports. A seam whose methods live in
#    its own <Class>+Debug.m must be compiled into that target too, or the
#    first test to send one of its selectors fails at run time. A header
#    reached for a class the target never compiles cannot be sent to, so it
#    is not required (AudioPlayer+Debug.h also declares the voice bus's
#    category, which VibeTests uses without the player).
#    A vibe-libs piece keeps each seam beside its class, so a +Debug header
#    there counts too. Its own tests and vendored code are left out.
#    Sources of a test target: its own entries plus its templates', with
#    directory entries expanded.
sources_for() {   # sources_for <target or template>
    awk -v t="$1" '
        /^  [A-Za-z][A-Za-z0-9_-]*:[ \t]*$/ { name = $1; sub(/:$/, "", name); insrc = 0; next }
        name != t                           { next }
        /^    sources:[ \t]*$/              { insrc = 1; next }
        /^    templates:/ {
            l = $0; sub(/^[^[]*\[/, "", l); sub(/\].*$/, "", l); gsub(/[ \t]/, "", l)
            n = split(l, arr, ","); for (i = 1; i <= n; i++) print "TEMPLATE\t" arr[i]; next
        }
        /^    [A-Za-z]/                     { insrc = 0; next }
        insrc && /^      - path:/ {
            p = $0; sub(/^[ \t]*-[ \t]*path:[ \t]*/, "", p); sub(/[ \t]*#.*$/, "", p); gsub(/"/, "", p)
            print "PATH\t" p
        }' project.yml \
    | while IFS=$'\t' read -r kind value; do
        case "$kind" in
            TEMPLATE) sources_for "$value" ;;
            PATH) if [ -d "$value" ]; then
                      find "$value" \( -name '*.m' -o -name '*.mm' \)
                  else
                      echo "$value"
                  fi ;;
        esac
    done
}

# Every "<file>\t<imported basename>" edge, and every header's path by basename.
libs_pieces=$(find vibe-libs -mindepth 1 -maxdepth 1 -type d \
                   ! -name Tests ! -name third_party ! -name docs ! -name scripts ! -name '.*' ! -name build)
import_edges=$(grep -rHo '^[[:space:]]*#[[:space:]]*import[[:space:]]*"[^"]*"' Vibe Tests $libs_pieces \
                    --include='*.h' --include='*.m' --include='*.mm' \
               | grep -v '/ThirdParty/' \
               | awk '{ f = $0; sub(/:.*$/, "", f); h = $0; sub(/^[^"]*"/, "", h); sub(/".*$/, "", h); sub(/^.*\//, "", h); print f "\t" h }')
header_paths=$(find Vibe Tests $libs_pieces -name '*.h' ! -path '*/ThirdParty/*' | awk -F/ '{ print $NF "\t" $0 }')
seam_impls=$( { find Vibe/Debug -path '*/Seams/*' \( -name '*+Debug*.m' -o -name '*+Debug*.mm' \)
                find $libs_pieces \( -name '*+Debug*.m' -o -name '*+Debug*.mm' \); } \
             | sed -E 's/.*\///; s/\.mm?$//')

for t in VibeTests VibeAudioTests; do
    srcs=$(sources_for "$t" | sort -u)
    missing=$(awk -F'\t' '
        FILENAME == ARGV[1] { if ($0 != "") { queue[++tail] = $0; seen[$0] = 1; s = $0; sub(/.*\//, "", s); sub(/\.mm?$/, "", s); stem[s] = 1 }; next }
        FILENAME == ARGV[2] { if ($0 != "") impl[$0] = 1; next }
        FILENAME == ARGV[3] { paths[$1] = paths[$1] "\n" $2; next }
        { edge[$1] = edge[$1] "\n" $2; next }
        END {
            while (head < tail) {
                f = queue[++head]
                m = split(edge[f], imps, "\n")
                for (i = 1; i <= m; i++) {
                    if (imps[i] == "") continue
                    k = split(paths[imps[i]], ps, "\n")
                    for (j = 1; j <= k; j++) {
                        p = ps[j]; if (p == "" || (p in seen)) continue
                        seen[p] = 1; queue[++tail] = p
                        if (p ~ /\/Seams\/[^\/]*\+Debug[^\/]*\.h$/ || p ~ /^vibe-libs\/.*\+Debug[^\/]*\.h$/) {
                            s = p; sub(/.*\//, "", s); sub(/\.h$/, "", s)
                            c = s; sub(/\+Debug.*$/, "", c)
                            if ((s in impl) && !(s in stem) && (c in stem)) miss[s] = miss[s] " " f
                        }
                    }
                }
            }
            for (s in miss) print s ".m, reached from" miss[s]
        }' <(echo "$srcs") <(echo "$seam_impls") <(echo "$header_paths") <(echo "$import_edges"))
    if [ -n "$missing" ]; then
        fail "$t compiles a seam header's users but not the seam — add it to the target's sources in project.yml:"
        echo "$missing" >&2
    fi
done

# 7. vibe-libs. project.yml includes vibe-libs/vibe-libs.yml, so a checkout without
#    the submodule fails late, in xcodegen or the build. A Vibe file names a
#    piece's header by its name: the piece's template puts it on the path, and
#    a relative path would tie the file to where the submodule sits.
if [ ! -f vibe-libs/vibe-libs.yml ]; then
    fail "vibe-libs/ is not checked out — run 'make project' or 'git submodule update --init vibe-libs'"
fi
by_path=$(grep -rnE '^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]+"[^"]*vibe-libs/' Vibe Tests \
    --include='*.h' --include='*.m' --include='*.mm' --include='*.c' --include='*.cpp' --include='*.pch' 2>/dev/null || true)
if [ -n "$by_path" ]; then
    fail "a file imports a vibe-libs header by path — import it by its name:"
    echo "$by_path" >&2
fi

if [ "$status" -eq 0 ]; then
    echo "✅ layout OK"
fi
exit "$status"

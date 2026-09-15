#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SAFETY CHECK 1 OF 4 -- THE LUA CODE IS PROVABLY UNCHANGED
#
# Compiles every .lua file in two trees and compares the INSTRUCTIONS the
# machine will run -- the opcodes, their operands, and every constant they
# refer to -- with the source line each instruction came from removed.
#
# Why the line numbers have to go: deleting a comment moves every line below
# it. Lua records where each instruction came from, and `luac -s` does not
# erase all of that -- each function keeps the line range it was defined
# over. So a raw byte comparison reports a difference for a pure comment
# removal, which is a check that cries wolf and is therefore no check at all.
# This was found by running it, before anything was deleted.
#
# What is left after the line numbers is the thing that matters: an identical
# result on both sides means these two files execute the same instructions,
# in the same order, on the same constants. Deleting a comment cannot change
# that. Deleting a character of real code always does.
#
# EITHER SIDE MAY BE A COMMIT. This was written for a working tree and its
# stripped copy, and that pair stopped existing the day the strip landed:
# there is no "before" directory in the tree any more, so the check read as
# unrunnable and went unrun. The "before" is now any commit. Give it a ref and
# it archives that ref into a scratch directory itself, so the check somebody
# reaches for at 2am is one command and not a recipe.
#
#   usage: verify_lua_identical.sh <before> <after>
#
#     <before> and <after> are each EITHER a directory OR anything git will
#     resolve to a commit -- a sha, a tag, a branch, HEAD~3. An existing
#     directory wins over a ref of the same name.
#
#     verify_lua_identical.sh 566171c 7fb527e        two commits
#     verify_lua_identical.sh 566171c Crimson-Arena  a commit against the tree
#     verify_lua_identical.sh /tmp/before /tmp/after two directories
#
#     A ref is archived whole and the Crimson-Arena/ inside it is what gets
#     compared, so the tools/ directory of that commit is not dragged in.
# ---------------------------------------------------------------------------
set -u

BEFORE_ARG="${1:?usage: verify_lua_identical.sh <before dir or git ref> <after dir or git ref>}"
AFTER_ARG="${2:?usage: verify_lua_identical.sh <before dir or git ref> <after dir or git ref>}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A directory if it is one, otherwise a commit unpacked into the scratch dir.
# NOT the other way round: a ref that happens to share a name with a directory
# on disk is the ambiguous case, and answering with the thing the caller can
# see is the one that cannot silently compare something they did not mean.
resolve() {
    local arg="$1" slot="$2" dir
    if [ -d "$arg" ]; then
        printf '%s' "$arg"
        return 0
    fi
    if ! git -C "$REPO" rev-parse --verify --quiet "$arg^{commit}" >/dev/null 2>&1; then
        echo "not a directory and not a commit: $arg" >&2
        return 1
    fi
    dir="$WORK/$slot"
    mkdir -p "$dir"
    if ! git -C "$REPO" archive "$arg" | tar -x -C "$dir"; then
        echo "could not archive $arg" >&2
        return 1
    fi
    if [ -d "$dir/Crimson-Arena" ]; then
        printf '%s' "$dir/Crimson-Arena"
    else
        printf '%s' "$dir"
    fi
}

BEFORE="$(resolve "$BEFORE_ARG" before)" || exit 2
AFTER="$(resolve "$AFTER_ARG" after)"    || exit 2
echo "before: $BEFORE_ARG  ->  $BEFORE"
echo "after:  $AFTER_ARG  ->  $AFTER"

# Strips: the [line] column on each instruction, the <file:first,last> range
# in each function header, and the hex address luac prints for the prototype.
normalise() {
    luac5.4 -l -l -s -o /dev/null "$1" 2>/dev/null \
        | sed -E 's/\[[0-9]+\]//g; s/<[^>]*:[0-9]+,[0-9]+>//g; s/0x[0-9a-f]+//g' \
        | sed -E 's/[[:space:]]+/ /g'
}

fail=0
checked=0
missing=0

while IFS= read -r rel; do
    a="$BEFORE/$rel"
    b="$AFTER/$rel"
    if [ ! -f "$b" ]; then
        echo "MISSING   $rel  -- the file is gone from the stripped tree"
        missing=$((missing + 1))
        continue
    fi
    ha=$(normalise "$a" | sha256sum | cut -d' ' -f1)
    hb=$(normalise "$b" | sha256sum | cut -d' ' -f1)
    checked=$((checked + 1))
    if [ -z "$ha" ] || [ "$ha" != "$hb" ]; then
        echo "CHANGED   $rel"
        diff <(normalise "$a") <(normalise "$b") | head -12 | sed 's/^/          /'
        fail=$((fail + 1))
    fi
done < <(cd "$BEFORE" && find . -name '*.lua' -not -path './tests/*' | sed 's|^\./||' | sort)

echo "---------------------------------------------------------------"
echo "compared $checked lua file(s): $fail changed, $missing missing"
if [ "$fail" -eq 0 ] && [ "$missing" -eq 0 ]; then
    echo "PASS -- every shipping Lua file executes the same instructions"
    exit 0
fi
echo "FAIL"
exit 1

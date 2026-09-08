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
#   usage: verify_lua_identical.sh <before-dir> <after-dir>
# ---------------------------------------------------------------------------
set -u
BEFORE="${1:?before dir}"
AFTER="${2:?after dir}"

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

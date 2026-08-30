#!/usr/bin/env bash
# tests/run.sh
#
# Runs every *_spec.lua in this directory under plain lua5.4. There is no test
# framework to install: shared/arena.lua calls no native, so a spec loads the
# REAL file through tests/fixtures/sandbox.lua and asserts with
# tests/testkit.lua, and lua5.4 -- the runtime fxmanifest.lua's `lua54 'yes'`
# ships against -- is the only dependency.
#
# Each spec is its OWN process: a spec that dies on a syntax error or a stray
# global cannot take the rest of the suite with it, and no spec can leak a
# mutated sandbox into the next one. This script aggregates their exit codes
# and fails if any one of them failed -- the same contract the `Specs` step in
# .github/workflows/lua-check.yml relies on.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Specs resolve '../config.lua' and 'fixtures/sandbox.lua' relative to the
# working directory, so the cd above is load-bearing, not tidiness.

LUA_BIN="${LUA_BIN:-lua5.4}"

if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
    echo "tests/run.sh: '$LUA_BIN' not found on PATH -- install Lua 5.4 (the runtime this resource ships against) to run this suite." >&2
    exit 2
fi

overall_status=0
total_files=0
failed_files=()

for spec in *_spec.lua; do
    [ -e "$spec" ] || continue
    total_files=$((total_files + 1))
    echo "==> $spec"
    if ! "$LUA_BIN" "$spec"; then
        overall_status=1
        failed_files+=("$spec")
    fi
    echo ""
done

echo "============================================================"
# No specs at all is a FAILURE, not a pass: a green tick from a suite that
# never ran is worse than a red one.
if [ "$total_files" -eq 0 ]; then
    echo "tests/run.sh: no *_spec.lua files found -- nothing ran."
    exit 2
fi

if [ "$overall_status" -eq 0 ]; then
    echo "ALL SPEC FILES PASSED ($total_files file(s))."
else
    echo "SPEC FILE(S) FAILED: ${failed_files[*]}"
fi

exit "$overall_status"

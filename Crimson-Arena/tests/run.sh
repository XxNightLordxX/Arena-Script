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
#
# It also runs the two gates CI runs BEFORE the specs -- parse and luacheck --
# so that a green run of this script means a green run of CI. See the block
# below for why that is worth the few seconds of duplication.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

# Specs resolve '../config.lua' and 'fixtures/sandbox.lua' relative to the
# working directory, so the cd above is load-bearing, not tidiness.

LUA_BIN="${LUA_BIN:-lua5.4}"

if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
    echo "tests/run.sh: '$LUA_BIN' not found on PATH -- install Lua 5.4 (the runtime this resource ships against) to run this suite." >&2
    exit 2
fi

# ----------------------------------------------------------------------
# THE TWO GATES CI RUNS BEFORE THE SPECS, AND THIS SCRIPT DID NOT.
#
# .github/workflows/lua-check.yml has three: every file PARSES, luacheck is
# clean against this resource's own allow-list, and the specs pass. Only the
# third was here -- so a green run of this script said nothing about the
# other two, and a change could be committed and pushed on the strength of it
# and still go red. That is not hypothetical; it happened, on a set of
# shadowed locals in a spec file, with the whole suite passing.
#
# They run FIRST, in CI's order, because a file that does not parse makes
# everything after it meaningless.
#
# Run twice in CI -- once as its own step, once here -- which costs a couple
# of seconds and is worth it: the alternative is a switch to turn this off,
# and a switch to turn a guard off is how the guard stops guarding. CI keeps
# its separate steps so its errors stay granular and annotate the right file.
#
# Both skip with a notice when the tool is absent, exactly as the Node panel
# tests below do. Neither is a dependency of the resource itself.
# ----------------------------------------------------------------------

LUAC_BIN="${LUAC_BIN:-luac5.4}"
LUACHECK_BIN="${LUACHECK_BIN:-luacheck}"

if command -v "$LUAC_BIN" >/dev/null 2>&1; then
    echo "==> parse (every .lua file)"
    parse_status=0
    while IFS= read -r -d '' file; do
        if ! "$LUAC_BIN" -p "$file"; then
            echo "tests/run.sh: $file DOES NOT PARSE under lua5.4." >&2
            parse_status=1
        fi
    done < <(find .. -type f -name '*.lua' -print0)
    if [ "$parse_status" -ne 0 ]; then
        echo "============================================================"
        echo "PARSE FAILED -- nothing else was run."
        exit 1
    fi
    echo "    every .lua file parses"
    echo ""
else
    echo "tests/run.sh: '$LUAC_BIN' not found -- SKIPPED the parse gate that CI runs first." >&2
fi

if command -v "$LUACHECK_BIN" >/dev/null 2>&1; then
    echo "==> luacheck"
    # From the resource root, which is where .luacheckrc lives and where CI
    # runs it from. A warning is a CI failure, so it is one here too.
    if ! ( cd .. && "$LUACHECK_BIN" . ); then
        echo "============================================================"
        echo "LUACHECK FAILED -- the specs were not run. CI treats a warning as a failure."
        exit 1
    fi
    echo ""
else
    echo "tests/run.sh: '$LUACHECK_BIN' not found -- SKIPPED the lint gate CI runs. Install it with" >&2
    echo "              'luarocks install luacheck', or your distribution's lua-check package." >&2
fi

overall_status=0
total_files=0
failed_files=()

# A SPEC IS JUDGED ON TWO THINGS: its exit code, and whether it reported a
# tally at all.
#
# The second half is not belt-and-braces. testkit runs every t.test() body in
# its own pcall, so a failing assertion fails that one test and nothing else
# -- the process still ends normally, and the ONLY thing that turns a failed
# test into a failed process is `os.exit(t.summary())` at the foot of the
# file. Two spec files had drifted off that: one never called summary at all,
# the other called it and threw the code away. Between them 20-odd tests
# could print [FAIL] while this script printed ALL SPEC FILES PASSED, which
# is the worst thing a test runner can do.
#
# So the tally line summary() prints is now required. A file that forgets the
# exit line fails here instead of passing silently, and nobody has to
# remember.
for spec in *_spec.lua; do
    [ -e "$spec" ] || continue
    total_files=$((total_files + 1))
    echo "==> $spec"

    spec_output=$("$LUA_BIN" "$spec" 2>&1)
    spec_status=$?
    printf '%s\n' "$spec_output"

    if [ "$spec_status" -ne 0 ]; then
        overall_status=1
        failed_files+=("$spec")
    elif ! printf '%s' "$spec_output" | grep -qE '^[0-9]+ passed, [0-9]+ failed$'; then
        echo "tests/run.sh: $spec exited 0 but printed no 'N passed, M failed' tally." >&2
        echo "              Its last line must be: os.exit(t.summary())" >&2
        echo "              Without it a failing test cannot fail this run." >&2
        overall_status=1
        failed_files+=("$spec (no tally)")
    fi
    echo ""
done

# ----------------------------------------------------------------------
# THE PANEL, RUN RATHER THAN READ.
#
# Every Lua spec that covers html/app.js asserts on its TEXT, which catches a
# wire that was never connected and cannot catch one connected to the wrong
# thing. tests/panel/ loads the real file into a DOM shim and asserts what it
# PUTS ON THE WIRE, which is the thing the server acts on.
#
# Node is not a hard dependency of this resource -- it runs in FiveM, which
# has its own JS runtime -- so a machine without it is told what it skipped
# rather than failed. CI has node and does run these.
# ----------------------------------------------------------------------
NODE_BIN="${NODE_BIN:-node}"

if command -v "$NODE_BIN" >/dev/null 2>&1; then
    for suite in panel/*.test.js; do
        [ -e "$suite" ] || continue
        total_files=$((total_files + 1))
        echo "==> $suite"
        if ! "$NODE_BIN" "$suite"; then
            overall_status=1
            failed_files+=("$suite")
        fi
        echo ""
    done
else
    echo "tests/run.sh: '$NODE_BIN' not found -- SKIPPED tests/panel/*.test.js," >&2
    echo "              which are the only tests that run html/app.js for real." >&2
fi

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

#!/usr/bin/env bash
# Crimson Arena: everything that must be true before this ships.
#
# One command, eight gates, in the order that fails cheapest first. A file that
# does not parse makes every check after it meaningless, so parsing goes first.
#
#   ./tools/verify_release.sh
#
# Exit 0 means every gate that COULD run, passed. Gates whose tool is absent skip
# with a notice rather than failing -- a missing luac on somebody's machine must
# not read as a broken resource. Gates that were SKIPPED are listed at the end,
# because a run that silently checked nothing is worse than a run that failed.
set -uo pipefail
cd "$(dirname "$0")/.."
R=Crimson-Arena

fail=0; skipped=()
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
skip() { printf '  SKIP  %s\n' "$*"; skipped+=("$1"); }
head_() { printf '\n== %s ==\n' "$*"; }

head_ "1. every Lua file parses"
if command -v luac5.4 >/dev/null 2>&1; then
    n=0; bad_files=""
    for f in $(find $R -name '*.lua' -not -path '*/tests/*'); do
        if luac5.4 -p "$f" >/dev/null 2>&1; then n=$((n+1)); else bad_files="$bad_files $f"; fi
    done
    [ -z "$bad_files" ] && ok "$n files parse" || bad "does not parse:$bad_files"
else skip "luac5.4 not installed"; fi

head_ "2. no local used before its definition"
# A local referenced above its own declaration compiles fine and is nil at run time.
# The symptom is that the name shows up as a GLOBAL in the bytecode. This has caught
# a real defect; it is one command and it is not optional.
if command -v luac5.4 >/dev/null 2>&1; then
    # Genuine globals this resource legitimately reads. ox_lib provides `locale`;
    # FiveM provides `source`, `vector3`, `vector4`, `joaat`, `quat` and friends;
    # fxmanifest.lua is a manifest, not a script, and every bare word in it is a
    # directive. Anything NOT matching this is a lowercase name reaching _ENV,
    # which is what a local used before its own definition looks like.
    KNOWN='^(Arena[A-Za-z]*|Config|Citizen|Entity|Player|Ped|Vehicle|exports|msgpack|json|promise|lib|MySQL|locale|source|vector2|vector3|vector4|quat|joaat|assert|collectgarbage|error|getmetatable|ipairs|load|next|os|pairs|pcall|print|rawequal|rawget|rawlen|rawset|require|select|setmetatable|string|table|tonumber|tostring|type|unpack|xpcall|math|utf8|debug|coroutine|[A-Z][A-Za-z0-9_]*)$'
    leaked=""
    for f in $(find $R -name '*.lua' -not -path '*/tests/*' -not -name 'fxmanifest.lua'); do
        for g in $(luac5.4 -l -l -p "$f" 2>/dev/null | grep -oP '_ENV "\K[A-Za-z_][A-Za-z0-9_]*'  | sort -u); do
            echo "$g" | grep -qE "$KNOWN" || leaked="$leaked $f:$g"
        done
    done
    [ -z "$leaked" ] && ok "no lowercase name leaks to _ENV" || bad "possible use-before-definition:$leaked"
else skip "luac5.4 not installed"; fi

head_ "3. the two non-Lua files"
if command -v node >/dev/null 2>&1; then
    node --check $R/html/app.js >/dev/null 2>&1 && ok "app.js is valid JavaScript" || bad "app.js does not parse"
else skip "node not installed"; fi
python3 -c "import json,sys;json.load(open('$R/locales/en.json'))" 2>/dev/null \
    && ok "en.json is valid JSON" || bad "en.json does not parse"

head_ "4. the production strip changes no behaviour"
# Strip a COPY and compare compiled instructions with line numbers removed. A
# comment cannot change them; a character of real code always does.
# EVERY .lua FILE, NOT JUST ammo.lua. This gate checked exactly one of the
# twenty and its heading spoke for the strip as a whole -- so a strip_prod.py
# change that mangled a construct ammo.lua happens not to use would have been
# reported as "the production strip changes no behaviour" and shipped. The same
# blind spot the panel suites had in gate 6, in a second costume: a gate is
# only worth what it actually looks at.
#
# Measured when this was widened: twenty files, ~65,000 instructions, zero
# differing. The narrow version was not hiding a live bug -- it was one file
# away from being unable to see one.
#
# WHY md5 OF THE OPCODE COLUMN. `luac5.4 -l -p` prints the line number beside
# every instruction, and stripping comments moves every line. Cutting the
# opcode name out of each row compares what the VM will do and ignores where it
# was written, which is the whole question this gate asks.
if command -v luac5.4 >/dev/null 2>&1; then
    T=$(mktemp -d); cp -r $R "$T/r" 2>/dev/null
    sp=0; sf=0; sbad=""; unparsed=""
    while IFS= read -r f; do
        rel=${f#$R/}
        python3 tools/strip_prod.py --header "Crimson Arena" "$T/r/$rel" >/dev/null 2>&1 || {
            sf=$((sf+1)); sbad="$sbad $rel(strip failed)"; continue; }
        a=$(luac5.4 -l -p "$f" 2>/dev/null | grep -oP '^\t\d+\t\[\d+\]\t\K\S+' | md5sum)
        b=$(luac5.4 -l -p "$T/r/$rel" 2>/dev/null | grep -oP '^\t\d+\t\[\d+\]\t\K\S+' | md5sum)
        if [ "$a" = "$b" ]; then sp=$((sp+1)); else sf=$((sf+1)); sbad="$sbad $rel"; fi
        luac5.4 -p "$T/r/$rel" >/dev/null 2>&1 || unparsed="$unparsed $rel"
    done < <(find $R -name '*.lua' -not -path '*/tests/*' | sort)

    if [ "$((sp+sf))" -eq 0 ]; then skip "no .lua files to strip"
    elif [ "$sf" -eq 0 ]; then ok "stripping all $sp .lua file(s) changes no instruction"
    else bad "the strip CHANGED behaviour in $sf of $((sp+sf)) file(s):$sbad"; fi

    [ -z "$unparsed" ] && ok "every stripped file still parses" \
        || bad "stripped file(s) do not parse:$unparsed"
    rm -rf "$T"
else skip "luac5.4 not installed"; fi

head_ "5. the harnesses"
if command -v lua5.4 >/dev/null 2>&1 && [ -d tools/harness ]; then
    p=0; f=0
    for h in tools/harness/*.lua; do
        if (cd tools/harness && lua5.4 "$(basename "$h")" >/dev/null 2>&1); then p=$((p+1)); else f=$((f+1)); echo "        failing: $h"; fi
    done
    [ "$f" -eq 0 ] && ok "$p harnesses pass" || bad "$f of $((p+f)) harnesses fail"
else skip "lua5.4 or tools/harness missing"; fi

head_ "6. the spec suite"
# TRACKED, and still not shipped: the production strip leaves tests/ where it
# is and the release does not carry it, but the repository does -- so the suite
# behind every claim in this project's history can be re-run by anyone who
# clones it. Running from a stripped copy rather than a clone is the one case
# where it is absent, and absent stays a skip rather than a failure.
#
# (The line that used to sit here told you to recover it with
#  'git archive 566171c Crimson-Arena/tests | tar -x'. That commit holds 74
#  specs; the suite is well past that now, so following it would have quietly
#  restored an old one over a newer one.)
if command -v lua5.4 >/dev/null 2>&1 && [ -d tests ]; then
    p=0; f=0; bad_specs=""
    for s in tests/*_spec.lua; do
        if (cd tests && timeout 120 lua5.4 "$(basename "$s")" >/dev/null 2>&1); then p=$((p+1))
        else f=$((f+1)); bad_specs="$bad_specs $(basename "$s")"; fi
    done
    [ "$f" -eq 0 ] && ok "$p Lua specs pass" || bad "$f of $((p+f)) Lua specs fail:$bad_specs"
else skip "spec suite not present (stripped for production -- this is normal)"; fi

# THE PANEL SUITES ARE HALF THE TESTS AND THIS GATE USED TO SKIP THEM ALL.
# The glob above is tests/*_spec.lua, which is 104 files; the other 25 are
# tests/panel/*.test.js, run by node, and they are the ONLY tests that execute
# html/app.js for real. Nothing here looked at them, so a panel suite could be
# failing -- or deliberately broken, which is how this was found -- and this
# script still printed READY. A release gate that greenlights a red tree is
# worse than no gate, because it is believed.
#
# JUDGED THE SAME WAY tests/run.sh JUDGES THEM: exit code alone trusts the
# suite to have remembered to set one, and run.sh's own comment records two
# files that had drifted off that line. So the tally has to be printed AND
# have to read zero failed.
#
# NODE ABSENT IS A SKIP, NOT A PASS, for the same reason the Lua branch skips
# on a stripped tree -- but it must never read as though the suites ran.
if [ -d tests/panel ] && command -v node >/dev/null 2>&1; then
    pp=0; pf=0; bad_panel=""
    for s in tests/panel/*.test.js; do
        [ -e "$s" ] || continue
        out=$(cd tests && timeout 120 node "panel/$(basename "$s")" 2>&1)
        if [ $? -eq 0 ] && printf '%s' "$out" | grep -qE '^[0-9]+ passed, 0 failed$'; then
            pp=$((pp+1))
        else
            pf=$((pf+1)); bad_panel="$bad_panel $(basename "$s")"
        fi
    done
    if [ "$((pp+pf))" -eq 0 ]; then skip "tests/panel holds no .test.js files"
    elif [ "$pf" -eq 0 ]; then ok "$pp panel suites pass"
    else bad "$pf of $((pp+pf)) panel suites fail:$bad_panel"; fi
elif [ -d tests/panel ]; then skip "node not installed -- the $(ls tests/panel/*.test.js 2>/dev/null | wc -l | tr -d ' ') panel suites did NOT run"
else skip "tests/panel not present (stripped for production -- this is normal)"; fi

head_ "7. every internal contract holds"
if [ -f tools/verify_contracts.py ]; then
    if out=$(python3 tools/verify_contracts.py "$R" 2>&1); then
        ok "$(printf '%s' "$out" | grep -c '^  ok')  contracts hold (locale keys, Config keys, NUI names, element ids, the manifest, the line map)"
    else
        bad "a contract is broken:"; printf '%s\n' "$out" | sed 's/^/        /'
    fi
else skip "tools/verify_contracts.py missing"; fi

head_ "8. nobody but the owner is credited"
if [ -x tools/verify_credit.sh ]; then
    ./tools/verify_credit.sh >/dev/null 2>&1 && ok "tree, messages, authors and trailers all clean" \
                                             || { bad "credit check failed"; ./tools/verify_credit.sh | sed 's/^/        /'; }
else skip "tools/verify_credit.sh missing"; fi

head_ "9. the dependency surface is intact"
if [ -f tools/inventory.py ]; then
    c=$(python3 tools/inventory.py $R 2>/dev/null | grep -cE '^' || echo 0)
    [ "$c" -gt 0 ] && ok "inventory.py ran ($c lines) -- compare against a known-good tree by hand" \
                   || skip "inventory.py produced nothing"
else skip "tools/inventory.py missing"; fi

printf '\n========================================\n'
if [ ${#skipped[@]} -gt 0 ]; then
    printf 'SKIPPED (checked nothing):\n'
    for s in "${skipped[@]}"; do printf '  - %s\n' "$s"; done
fi
[ "$fail" -eq 0 ] && printf 'READY -- every gate that ran, passed.\n' \
                  || printf 'NOT READY -- fix the failures above.\n'
printf '========================================\n'
exit $fail

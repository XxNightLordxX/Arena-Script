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
if command -v luac5.4 >/dev/null 2>&1; then
    T=$(mktemp -d); cp -r $R "$T/r" 2>/dev/null
    if python3 tools/strip_prod.py --header "Crimson Arena" "$T/r/server/ammo.lua" >/dev/null 2>&1; then
        a=$(luac5.4 -l -p $R/server/ammo.lua 2>/dev/null | grep -oP '^\t\d+\t\[\d+\]\t\K\S+' | md5sum)
        b=$(luac5.4 -l -p "$T/r/server/ammo.lua" 2>/dev/null | grep -oP '^\t\d+\t\[\d+\]\t\K\S+' | md5sum)
        [ "$a" = "$b" ] && ok "stripping ammo.lua changes no instruction" || bad "the strip CHANGED ammo.lua's behaviour"
        luac5.4 -p "$T/r/server/ammo.lua" >/dev/null 2>&1 && ok "stripped file still parses" || bad "stripped file does not parse"
    else skip "strip_prod.py did not run"; fi
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
# NOT shipped -- stripped for production on purpose. Recover it into place with
#   git archive 566171c Crimson-Arena/tests | tar -x
# and it is picked up here automatically. Absent is normal, not a failure.
if command -v lua5.4 >/dev/null 2>&1 && [ -d $R/tests ]; then
    p=0; f=0; bad_specs=""
    for s in $R/tests/*_spec.lua; do
        if (cd $R/tests && timeout 120 lua5.4 "$(basename "$s")" >/dev/null 2>&1); then p=$((p+1))
        else f=$((f+1)); bad_specs="$bad_specs $(basename "$s")"; fi
    done
    [ "$f" -eq 0 ] && ok "$p specs pass" || bad "$f of $((p+f)) specs fail:$bad_specs"
else skip "spec suite not present (stripped for production -- this is normal)"; fi

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

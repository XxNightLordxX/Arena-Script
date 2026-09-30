#!/usr/bin/env bash
# Run the production strip over a whole copy of the resource.
#
# ONE HEADER PER FILE, WRITTEN OUT HERE RATHER THAN GENERATED. The whole
# point of the line is that somebody who does not read code can open the
# folder and tell what each file is for, and no rule derived from a filename
# can say that. Nine words, in the language of the game rather than the
# language of the program.
#
# A HAND-WRITTEN LIST GOES STALE SILENTLY, which is how a file ships with its
# comments still in it. Nothing here used to notice a code file the list did
# not mention: the run stripped nineteen files, said so, and exited 0 whether
# the folder held nineteen or twenty. So the list is now checked against the
# tree BEFORE anything is stripped -- every code file must be either named
# below or listed as deliberately exempt, and every name below must exist --
# and a mismatch stops the run rather than quietly skipping a file.
#
#     usage: strip_all.sh <path to a copy of Crimson-Arena>
set -euo pipefail

ROOT="${1:?usage: strip_all.sh <path to a copy of Crimson-Arena>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

NAMED=()
HEADERS=()
strip() { NAMED+=("$1"); HEADERS+=("$2"); }

# NOT STRIPPED, ON PURPOSE. Both were rewritten by hand for the operator
# rather than mechanically thinned, and the block rule -- which keeps only
# what warns -- would take out the plain sentences that are the entire point
# of the rewrite. They already carry their own headers.
#
# THIS IS A LIST AND NOT A COMMENT because the check below reads it: an
# exemption written in prose exempts nothing, and a code file nobody has
# decided about must stop the run rather than pass through it.
EXEMPT=(config.lua fxmanifest.lua)

strip client/dispatch.lua       'Crimson Arena: keeping the police and the medics out of the arena.'
strip client/main.lua           'Crimson Arena: the arena ped, the doors, and opening the panel.'
strip client/match.lua          'Crimson Arena: what a fighter sees and does during a round.'
strip client/spectate.lua       'Crimson Arena: watching a round you are not in.'
strip client/ui.lua             'Crimson Arena: the wire between the panel and the server.'
strip config.weapons.lua        'Crimson Arena: the weapons the arena may hand out.'
strip html/app.js               'Crimson Arena: how the panel behaves. Screens, forms, live updates.'
strip html/index.html           'Crimson Arena: what the panel is made of.'
strip html/style.css            'Crimson Arena: what the panel looks like.'
strip server/ammo.lua           'Crimson Arena: kit in, kit out. Weapons, rounds, and the safe.'
strip server/betting.lua        'Crimson Arena: the book. Stakes, odds, and who gets paid.'
strip server/dispatch.lua       'Crimson Arena: keeping arena gunfire off the city call system.'
strip server/lobby.lua          'Crimson Arena: lobbies. Joining, leaving, teams, and readiness.'
strip server/main.lua           'Crimson Arena: the front door. Every message the panel sends.'
strip server/match.lua          'Crimson Arena: the round itself. Countdown, kills, and endings.'
strip server/stats.lua          'Crimson Arena: the record. Wins, kills, streaks, and the database.'
strip server/util.lua           'Crimson Arena: small helpers the rest of the server shares.'
strip shared/arena.lua          'Crimson Arena: the rules both sides agree on. Modes, arenas, sums.'
strip shared/compat/dispatch.lua 'Crimson Arena: talking to whichever dispatch script you run.'

# ---------------------------------------------------------------------------
# THE LIST ABOVE MUST ACCOUNT FOR EVERY CODE FILE IN THE TREE.
#
# Three ways it can be wrong, and all three are silent without this:
#
#   a file exists that nothing above mentions   -- it ships with its comments
#   a name above has no file                    -- a rename nobody followed
#   an exemption has no file                    -- an exemption for nothing,
#                                                  which will silently exempt
#                                                  a future file of that name
#
# tests/ is excluded because it is not shipped.
# ---------------------------------------------------------------------------
missing=()
for rel in "${NAMED[@]}"; do
    [ -f "$ROOT/$rel" ] || missing+=("$rel")
done

stale=()
for rel in "${EXEMPT[@]}"; do
    [ -f "$ROOT/$rel" ] || stale+=("$rel")
done

covered=" ${NAMED[*]} ${EXEMPT[*]} "
unnamed=()
while IFS= read -r rel; do
    case "$covered" in
        *" $rel "*) ;;
        *) unnamed+=("$rel") ;;
    esac
done < <(cd "$ROOT" && find . -name tests -prune -o -name .git -prune -o -type f \
             \( -name '*.lua' -o -name '*.js' -o -name '*.css' -o -name '*.html' \) -print \
         | sed 's|^\./||' | sort)

if [ ${#missing[@]} -ne 0 ] || [ ${#unnamed[@]} -ne 0 ] || [ ${#stale[@]} -ne 0 ]; then
    echo "STOP -- strip_all.sh and $ROOT no longer agree, and NOTHING has been stripped." >&2
    for rel in ${missing[@]+"${missing[@]}"}; do
        echo "  NAMED BUT ABSENT   $rel  -- a rename or a deletion nobody followed here" >&2
    done
    for rel in ${unnamed[@]+"${unnamed[@]}"}; do
        echo "  PRESENT BUT UNNAMED $rel  -- would have SHIPPED WITH ITS COMMENTS" >&2
    done
    for rel in ${stale[@]+"${stale[@]}"}; do
        echo "  EXEMPT BUT ABSENT  $rel  -- drop it from EXEMPT before it exempts something else" >&2
    done
    echo "Add the file to the list with its own header line, or to EXEMPT if it is" >&2
    echo "deliberately left alone. Do not delete this check." >&2
    exit 1
fi

echo "list checked: ${#NAMED[@]} file(s) named, ${#EXEMPT[@]} exempt, none unaccounted for"

for i in "${!NAMED[@]}"; do
    python3 "$HERE/strip_prod.py" --header "${HEADERS[$i]}" "$ROOT/${NAMED[$i]}"
done

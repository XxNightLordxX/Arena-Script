#!/usr/bin/env bash
# Run the production strip over a whole copy of the resource.
#
# ONE HEADER PER FILE, WRITTEN OUT HERE RATHER THAN GENERATED. The whole
# point of the line is that somebody who does not read code can open the
# folder and tell what each file is for, and no rule derived from a filename
# can say that. Nine words, in the language of the game rather than the
# language of the program.
#
#     usage: strip_all.sh <path to a copy of Crimson-Arena>
set -euo pipefail

ROOT="${1:?usage: strip_all.sh <path to a copy of Crimson-Arena>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

strip() { python3 "$HERE/strip_prod.py" --header "$2" "$ROOT/$1"; }

strip client/dispatch.lua       'Crimson Arena: keeping the police and the medics out of the arena.'
strip client/main.lua           'Crimson Arena: the arena ped, the doors, and opening the panel.'
strip client/match.lua          'Crimson Arena: what a fighter sees and does during a round.'
strip client/spectate.lua       'Crimson Arena: watching a round you are not in.'
strip client/ui.lua             'Crimson Arena: the wire between the panel and the server.'
# config.lua and fxmanifest.lua are NOT run through the stripper. Both were
# rewritten by hand for the operator rather than mechanically thinned, and the
# block rule -- which keeps only what warns -- would take out the plain
# sentences that are the entire point of the rewrite. They already carry their
# own headers.
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

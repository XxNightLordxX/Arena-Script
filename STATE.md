# Where this stands

**For:** John Allday. **Updated:** during the review session that followed the handover.
Everything below was measured or reproduced, not reasoned about. Where something is
unproven it says so.

---

## The one thing to do first, and it is not code

**Check your FiveM server artifact version.** In the server console: `version`, or read
the build number out of your artifacts folder path.

The ally glow **is implemented** and has been since 31 August — a real ped outline, drawn
through walls, tinted from your team's own colour. Thirteen commits have touched it. It
renders only if the artifact provides `SetEntityDrawOutlineRenderTechnique`, a native
FiveM added around **May 2025**. On an older artifact the code silently skips it, the
outline call does nothing, raises no error, and the log then says `drawing 1 teammate(s)`
— true about a frame that drew nothing.

Worse, the warning that says it cannot work on this build is printed with `print` on the
**client**, so it only ever reached F8 in your own game, never the server console you read.
You have been shown a success message while the failure notice went somewhere invisible.

If your artifact predates May 2025 that alone explains every failed attempt. An overhead
marker is being added as well, because `SetMpGamerTag` has **zero commits in 336** and
works on every build back to 2019.

Note: only `tdm` has `teams = true`. `ffa` and `gungame` are `teams = false`, so there is
no ally glow in them by design.

---

## Landed and pushed

| Commit | What |
|---|---|
| `fe93a51` | The credit check. Four parts, proved by mutation: a tool name in a file is caught, the branch name alone is not, both on one line is caught, a foreign co-author trailer is caught. All 334 commits and the whole tree pass. |
| `b74d175` | `itemsIn` resolved each item's slot from the inventory key — the key is the authority, ox omits `item.slot` on some builds — then threw it away, so `copiesOf` read nil and `removeSlot` refused **without ever calling RemoveItem**. Every by-slot take-back silently did nothing. Suite went 61 to 75 of 77. |
| `6f69a77` | `tools/verify_release.sh` — eight gates in one command. Gate 2 (a local used before its own definition) was itself checked against a mutation, because a gate never seen to fire is not a gate. |

## The spec suite, now kept in the repository

**It is in the tree.** `Crimson-Arena/tests/`, tracked, and it runs with:

    bash Crimson-Arena/tests/run.sh

It used to be untracked, and this section used to tell you to recover it with
`git archive 566171c Crimson-Arena/tests | tar -x`. **Do not do that** -- that commit
holds 74 specs of an older shape and restoring it would put them over the 96 that are
here now. The instruction is left visible rather than deleted because it was followed
before, and anybody rereading an old copy of this file needs to know it is wrong.

Tracked is not the same as shipped: `tools/strip_prod.py` does not touch `tests/`, the
production release still does not carry it, and CI's shipped-code gates skip it (its
parse gate does not -- a spec that will not parse is worth failing a push for).

| | pass | fail |
|---|---|---|
| `566171c` (last commit where the specs were current) | 74 | 0 |
| HEAD when the recovery session started | 61 | 13 |
| HEAD at the end of that session | 75 | 2 |
| HEAD now, whole suite via `run.sh` | **114 files** | 0 |
| HEAD now, via `tools/verify_release.sh` | **93 specs** | 0 |

The two failures in that third row were **stale specs, not broken code**: `gungame_spec`
asserted on `ArenaAmmo.OnLoan`, deleted on purpose, and `moneyconservation_spec` predated
a deliberate third forfeit path. Ten of the original thirteen were likewise stale and
were proved so one by one. Both have since been settled -- the whole suite is green.

Three specs that appeared to hang are **merely slow** — 22 to 40 seconds — and all pass.
No non-terminating loop exists anywhere in the shipped code.

---

## Confirmed and still open, worst first

1. **Gun game leaves you unarmed from your first death.** Measured across six lives:
   armed, then unarmed five times. The respawn handler re-issues only when there is no
   ladder, and ox drops a dead fighter's inventory on the floor, so every death empties
   the pockets. A climber who dies before their first kill is unarmed for the whole round.
   Pre-existing, live now. Being fixed.
2. **A player's whole stash can be lost for ever after a restart.** One transient empty
   read latches `probed[citizenid]`, which is written in one place and cleared in none, and
   that character is never looked at again for the life of the process — no log line,
   because the warning sits inside the branch that was skipped. Phone and cash both.
3. **The arena can eat a player's own property.** ox answers `nil` for an unloaded
   inventory; the exit reads `nil` as refusal correctly, but every issue path reads it as
   success. A fighter placed a moment before their inventory loads is booked for a loadout
   that never arrived, against a floor of zero, and the exit takes 220 rounds and 5
   bandages of their own. A routine `restart ox_inventory` reaches it.
4. **`handBack` duplicates, and it compounds** — 3 gold bars became 9 over two rounds with
   9 more still in the stash.
5. **Money is created.** A half-finished payout is paid again by teardown: +15,000 proved
   on a 15,000 pot. The `settling` flag narrows the window rather than closing it, and on
   the shipped config it is never set at all.
6. **One player can cancel every round on the server, free, forever** — join, wait for
   Start, leave during the countdown with a full refund, rejoin. In TDM one person can
   cancel a 3v1.
7. **A round can wedge permanently** with players' money held and no settlement path: no
   sweep looks at a `countdown` match whose players are already placed.
8. **The kill-denial button.** A death naming no killer books unconditionally from any
   distance. Under `score_limit`/`most_kills` a denied kill is worth a scored one; proved
   to force a draw and a refunded pot. Your ruling: cost, never elimination.
9. **A config comment can lock you out of your own server.** `config.lua:46-48` says an
   empty group list means everyone; the code means nobody.
10. **`config.weapons.lua:18` still says explosives and launchers are disabled.** All 96
    weapons are enabled — your own instruction. The setting is right, the header lies.
11. **Five comment blocks still teach `fighterBets.max = 50000`**, the ceiling you halved.
    They survive the strip, so they ship, and they read authoritatively enough that the
    next editor restores 50,000.
12. **`outsideTicks = 0` silently clamps to 1**, so one sighting ejects a fighter and
    forfeits their stake — under a comment saying one sighting is never enough.

## Checked and sound — do not pay to re-check these

No XSS anywhere in the tablet (every name path is `textContent`). All 131 locale keys
resolve with correct placeholder counts. 50,076 hostile payloads across every net event
raised nothing and broke no state. All 356 config keys are read; none is dead. Rounding
conserves to the dollar over 1.2M cases. The admin gate is genuinely server-side — the
tablet is not the gate. `source` is never stale: there is no `MySQL.await` or
`callback.await` anywhere on the server. A stolen weapon keeps serial, stolen flag, owner,
registration, components and tint through the door, and a gun carrying a serial the arena
did not issue is left with the player. `neverStash` cannot smuggle arena kit.

## Decisions you made this session

* Never eject an honest player — no change may make ejection more likely.
* A death costs something but never elimination; `score_limit` and `most_kills` keep
  never eliminating anybody.
* The gun-game tier cap stays off.
* Every value in `config.lua` is yours; nothing changes without asking.
* Forfeit on a quit, refund on an admin stop.
* Ally marking: outline **and** an overhead marker. Allies only; enemies unmarked.

## Your logo

Overwrite `Crimson-Arena/html/images/logo.png`. Already in the manifest, nothing else to
change. `Config.UI.logoStyle` is `'mark'` (small square) or `'banner'` (spans the top and
replaces the title text). Use a transparent PNG; square suits `mark`, roughly 4:1 suits
`banner`.

---

## Late finding, arrived after the rest — and it resolves a disagreement

Two agents had disagreed about whether money was really being destroyed. One said the
failing `moneyconservation_spec` was stale and the forfeits deliberate. The other now has
the answer, measured:

**A forfeited entry stake is destroyed whenever the pot is NOT WON.** `betting.lua:679`
refuses to refund a forfeited stake on *every* teardown, including the ones where nobody
won it. Everybody dropping out mid-round destroys the whole pot: purse minus 3,000,
nothing on the unpaid ledger, and the log says "stays in the pot" one line before the pot
ceases to exist.

This is the **root cause of the `moneyconservation_spec` failure**, so that spec was NOT
stale after all — all 28 bad seeds are negative deltas. The earlier "stale spec" verdict
was wrong, and it is recorded here rather than quietly dropped.

The fix is six lines at `betting.lua:679`: refund a forfeited stake on a teardown that has
no winner. Applied to a copy and measured — `moneyconservation_spec` goes 10 passed 1
failed to **11 passed 0 failed**, with the whole 77-spec suite byte-identical otherwise
(both trees run end to end and diffed). That would take the suite to **77 of 77**.

One deliberate half is left alone and is your call: `betting.lua:858` / `:510` carries a
"DO NOT drop this again" comment.

**How this sits with your ruling.** You decided "forfeit on a quit, refund on an admin
stop". This is a third case neither of us named: the round collapses and *nobody* wins, so
there is no pot for the forfeit to go to and the money simply evaporates. Refunding it
there is closest to the spirit of both your ruling and EXPLOITS decision 7, but it is
yours to confirm.

### Two corrections to what is written above

* The gun-game climber wedge is real, but **two of its three sub-claims are refuted**: a
  weapon destroyed on death does *not* refuse, and a refused `giveWeapon` does roll back.
  The actual latch is a **serial-less record at `ammo.lua:938`** — the row is never pruned,
  so every later `settleTier` refuses identically, and `match.lua:1236` re-issues nothing
  on a ladder respawn. Fix the record pruning, not the death path.
* `ArenaMatch.Abort` lacks `End`'s `state == 'ended'` guard, so a re-entrant Stop pays the
  pot twice (+2,000). **Not reachable on a stock server** because `End` never yields, but
  one line closes it.

### Also proven clean by that pass

Database down: nothing hard-errors, money is conserved, kits are returned. Seven of the
thirteen unhappy-path scenarios are clean in full. Forty-five randomised lifecycles across
three database modes raised zero errors and left no match behind. `onResourceStop` does
exactly what it claims.

# Where this stands

**For:** John Allday. **Updated:** during the review session that followed the handover.
Everything below was measured or reproduced, not reasoned about. Where something is
unproven it says so.

---

## Reported from live play, and what is actually causing it

Three defects reported off a running server. Two are fixed and proven; the third is
diagnosed and has a one-line server.cfg mitigation.

### 1. Players come out of the arena invisible -- FIXED

**It was the routing bucket, which was the right instinct.**

`EnterBucket` proves its move landed: `moveTo` writes the bucket, reads it back, and says
at length why -- setting a routing bucket is a synchronous write, so a disagreement is
never "not yet", it is the native having done nothing. **`ExitBucket` never asked.** It
called `SetPlayerRoutingBucket` inside a `pcall` and looked only for a *throw*, so a
native that is accepted and does nothing -- exactly what FXServer does with these when
routing buckets are unavailable -- read as a clean exit.

A player left in the match's bucket is invisible to every other player on the server and
every one of them is invisible to them. Kit back, stood at the lobby ped, panel working,
alone on the server -- and not one line in any log, because nothing on that path ever
looked.

Now read back, retried once, and reported with the player, both bucket numbers and the
OneSync mode. Four tests in `isolation_spec.lua`, two of them controls; the guard was
inverted in a worktree and three tests fired.

**The rest of the bucket bookkeeping was then double-checked by measurement**, driving the
real server stack (`util` + `dispatch` + `betting` + `lobby` + `match` + `main`) rather
than reasoning about it. Every way out returns the player to bucket 0:

| Path | Bucket after |
|---|---|
| fighter leaves by the panel | 0 |
| fighter disconnects mid-round | 0 |
| spectator disconnects while watching | 0 |
| fighter disconnects during the countdown | never bucketed |
| the resource stops mid-round | 0 |
| **restore native accepted and inert** | **stays in the arena bucket -- now reported** |

So the bookkeeping is sound and the only hole was the unverified write. If players are
still coming out invisible after this, the log will now say so outright; if it says
nothing, the cause is not the bucket.

### 2. Belongings duplicated after a match -- FIXED

**Reproduced end to end through the real door, and it has nothing to do with
`Config.Database.enabled`.** That flag only governs the leaderboard and the outstanding-kit
slate; it never touches ox_inventory.

The exit handed over **whatever was in the belongings stash**. Nothing anywhere asked
whether the stash was still holding what the door left there. A player owning
`ammo-rifle x40, burger x3, phone x1` walked out of one round holding:

```
ammo-rifle x40, burger x3, burger x3, lockpick x2, phone x1, phone x1
```

Two of most of it and one item they had never owned -- "the items they had and didn't
have", precisely.

**How things get into that stash while a round is running.** ox_inventory throws an idle
inventory out of memory after `inventory:cleartime` (**five minutes** by default;
`modules/inventory/server.lua:2411`, purge cron at `:2463`, the sweep at `:2449`-`:2457`)
and reloads it from the database on the next touch (`:678`, `:640`, `:868`). `inv.time` is
stamped at creation and refreshed **only when an inventory is closed** (`:625`, `:351`) --
and nobody ever opens the arena's belongings stash, because it is a holding pen. So every
round longer than about five minutes round-trips the player's belongings through a
database row, and a row that did not get its last write comes back holding an **older
round's contents**. It is also a real stash with a predictable name, so an admin tool or
another resource can write to it.

**The fix is in this resource, not in the mitigation.** `stow` now reports how many rows
are in the stash the moment the door shuts, the record carries that as `allowed`, and
`handBack` will not hand over more rows than that. The surplus is **never destroyed** -- it
stays in the stash, and the stash is shut the way `jammedStash` shuts one the arena cannot
account for: nothing more goes in or out of it until somebody looks.

That ceiling is the **larger** of a read-back of the stash and a count of what went in,
because every way of being wrong here has a safe direction and it is the same one. A merge
makes the read smaller than the count; a split makes the count smaller than the read; and a
stash ox_inventory has unloaded answers an **empty list** rather than an error, which on a
read alone would be a ceiling of zero -- refusing a player their entire kit. Removing the
count floor and running the suite does exactly that: the control test's player walks out
with nothing at all.

All three guards are load-bearing and each was proved by inverting it alone in a worktree.
Leaving the surplus behind without shutting the stash was not enough: `ReturnLeftovers` is
uncapped on purpose (after a restart nothing knows what went in, and a ceiling of zero
there would refuse a player their whole kit), so the sweep collected the exact rows the
exit had just refused and handed them over a tick later.

Four tests in `doorguarantee_spec.lua`, **two of them controls** -- the one that matters is
that the leftovers of an earlier exit that could not finish still come back, because those
are the player's and a ceiling that refused them would be worse than the defect.

**Still worth doing:** put `set inventory:cleartime 60` in `server.cfg`. The ceiling stops
the duplication; raising the idle window stops the round-trip that causes it, and it is
also the only thing that helps the police bag below.

### 3. The police bag comes back empty -- FIXED

A container item does not carry its contents in its metadata. ox_inventory keeps them in a
**separate inventory** keyed by `metadata.container` (`modules/inventory/server.lua:294`
-`:298`), and the bag holds nothing but that key. So stashing the bag stashes a
**reference** -- and that inventory is never open and never a player, which puts it in the
same five-minute idle purge as everything else: written out, dropped, and read back from
the database on the next touch (`:757`, `:868`). If that round trip does not come back, the
bag returns with nothing in it.

The arena now takes the contents into its own keeping for the length of the round, one
holding stash per container (`crimson_arena_bag_<container id>`), and puts them back into
the same bag at the exit. The player gets it back packed the way they left it.

Three things make it safe:

- **Reached through the slot, never the id.** `GetInventoryItems(containerId)` answers
  nothing for a container ox_inventory has unloaded -- an id that is not a registered stash
  resolves to nothing at all, so a container cannot be revived by name. `GetContainerFromSlot`
  is the one export that creates it when missing, and it needs the slot the bag occupies.
  That is why both halves run while the bag is in somebody's hands rather than in a stash.
- **Nothing is created and nothing is destroyed.** Items only move, and every move is read
  before the item is taken out of where it was. A refusal at the door leaves the item in the
  bag, which is exactly the behaviour this resource has always had. A refusal at the exit
  leaves it in a real stash the log names.
- **It is not an exploit route.** A fighter cannot open a bag mid-round: the swapItems hook
  already refuses every move whose other end is not their own inventory, and a container's
  inventory id is not their server id. The bag is empty for the whole round.

The sweep refills too, without needing a record: a bag names its own container and the
holding stash is named from that container, so the keys are read straight off whatever bags
the player is carrying. That covers the exit that could not finish and the server that went
down mid-round.

Six tests in `doorguarantee_spec.lua`, four of them controls -- an ordinary round must
change nothing about the bag, an empty bag is left alone, `emptyContainers = false` keeps
the old behaviour, and an ox_inventory with no `GetContainerFromSlot` costs nothing. Two
separate mutations were used: switching the custody off (the bag comes back empty) and
aiming the refill at the player's pockets instead of the bag (the contents come back loose).

`Config.Loadouts.inventory.emptyContainers` turns it off.

### 3b. Two rough edges in the fixes above, found by reviewing them

**A jam was a dead end.** Three separate failures in `server/ammo.lua` stop the door
touching a stash, and all three print "settle it by hand" -- but nothing cleared the flag,
which lived and died with the resource. An operator could follow those instructions exactly
and the stash stayed dead, which also meant that player was never stripped at the door
again for the rest of the server's uptime. `/arenaunjam` now lists what is held back and
clears it, by name or `all`. Admin-gated, and deliberately **not** automatic: "clear it when
the stash reads empty" would key the recovery to the one answer this whole file refuses to
trust, since that is exactly what ox_inventory says about an inventory it has not loaded.

**The ceiling refused the wrong rows.** It kept the first `allowed` rows in slot order, and
slot order is not ownership -- a stale copy in a lower slot was handed over and the real row
was the one left behind. The exit now takes a manifest of what was in which slot when the
door shut, and refuses the rows that do **not** match it first. The manifest only chooses;
it never counts, because a reload can renumber slots and a manifest that decided *how many*
would then refuse everything and clear a player out. Measured by inverting the ordering
alone: the player came out with `burgerx3,lockpickx2,phonex1` -- their rifle ammo gone, a
lockpick they never owned in its place.

**And the bag holding stashes were registered with no owner**, which in ox_inventory means
*shared* -- unlike the belongings stash, which is owned by citizenid precisely so one player
cannot open another's. They are owned now, on both the way in and the way out; a stash
registered under a different owner is a different stash, and on the refill path that would
have read empty and quietly never given the contents back.

### 3c. Re-checking the fixes turned up one thing they had not covered

Every fix above was re-driven in scenarios the original tests did not reach, through the
real server stack: a bag owner **disconnecting** mid-round, **two rounds back to back** with
the same bag, **two players each with their own bag**, the belongings stash **jamming** while
bag contents are held, and the **resource stopping** mid-round. All five come out packed and
uncrossed; the two most regression-prone are now tests.

**And the countdown watchdog was never being driven.** `server/match.lua` aborts a match
that sits in `countdown` more than thirty seconds past its start -- the state a match lands
in if the thread that promotes it to `live` ever dies, where players stand in the arena
unable to fight, stakes are held, and nothing from the panel can reach them. Its comment
ends "DO NOT delete this branch: it is the only way out of that state."

Neutralising it left **all 114 spec files green**, which is the same as it not being there.
It now has a test, in `countdownexit_spec.lua`, plus a control that an over-eager watchdog
would fail.

Worth recording how that test had to be written, because the first version was worthless:
asserting "the match is no longer in countdown" passes whether the watchdog fires or not,
since the countdown simply going **live** satisfies it too. The observable that only the
abort produces is the fighters being **sent home** -- that is what it asserts now, and that
version goes red with the branch disabled.

One thing considered and deliberately not guarded: `Arena.IsKey` is only "non-empty string",
so `crimson_arena_<citizenid>` and `crimson_arena_bag_<container id>` could in principle
collide if a citizenid began with `bag_`. Framework-generated ids do not, and the guard
would cost more noise than the risk is worth. Noted rather than fixed.

### 4. And no match duplicates anything, asserted rather than argued

The general form of every defect above is "it is in two places now", and a test that looks
at one inventory cannot see it. So there is now a total: every item this server holds --
pockets, belongings stashes, bag-holding stashes, the insides of bags -- counted before a
match and after it, across **four** ways out (a normal end, a fighter leaving mid-round, a
fighter disconnecting, the resource stopping mid-round). Nothing players own may appear or
go; what the arena issues is excluded, because that is created at the door and destroyed at
the exit on purpose.

Proved by mutation: making the hand-back give an item over without taking it out of the
stash tripled everything, and the assertion names it item by item -- `ammo-rifle-ap 80 ->
240; burger 6 -> 18; phone 2 -> 6; police_bag 1 -> 3`.

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
holds 74 specs of an older shape and restoring it would put them over the 93 that are
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

> **RE-CHECKED, and most of this list is no longer true.** Each item below was
> tested by switching the guard that answers it OFF in a throwaway copy of the
> tree and running the whole suite. Where a test goes red, the fix is both
> present and defended.
>
> | # | Now | Evidence |
> |---|---|---|
> | 1 | **Fixed and held** | The respawn tops the fighter up through `ArenaAmmo.Refresh`. Both halves are pinned: free-for-all, and a climber killed on the first rung. |
> | 2 | **Fixed and held** | The empty-read latch no longer latches on one look; `stashrelook_spec` goes red if it does. |
> | 3 | **Fixed and held** | An unread floor means the exit takes nothing and writes nothing down, rather than billing a fighter for their own rounds; `ammo_spec` pins it. |
> | 4 | **Fixed and held** | A stash the door could not empty is shut instead of handed out twice. Removing the guard turns 2 waters into 4. |
> | 5 | **Fixed, NOT held** | The second-payout refusal now sits above the entry-pot branch, where it is reachable on the shipped config. No test fires when it is removed -- a complete payout empties the pot anyway, and the case where it bites is a payout that dies part-way, which no fixture can build. |
> | 6 | **Fixed and held** | Leaving during an unplaced countdown is refused; `holdstart_spec` pins the refusal for a player and for the host. |
> | 7 | **Fixed** | A countdown that never becomes a round is called off after 30 seconds of overrun. The branch names this exact defect and says it is the only way out of the state. Not verified as HELD -- no test was found that exercises the overrun. |
> | 8 | **Fixed and held** | A death naming nobody -- including a server id that is nobody in the round -- is priced, never elimination, which is the ruling you gave. Narrowing the predicate back turns `unwitnessedclaim_spec` red. |
> | 9 | **Fixed** | `config.lua` now states the trap in as many words: an empty `adminGroups` means NOBODY, and emptying it locks every player out including you. The code agrees -- only the console (source 0) is exempt. |
> | 10 | **Fixed** | The header says 93 of the 96 entries are enabled, names all thirteen heavy weapons, and names the three that are not. |
> | 11 | **WAS STILL TRUE. Fixed now.** | Two comments in `server/betting.lua` still said, in the present tense, that `fighterBets.max` ships at twice the spectator ceiling. Both ship at 25,000 -- level -- so a reader would have concluded the config was wrong and restored 50,000, which is the exploit those comments describe. |
> | 12 | **No longer silent** | The clamp stands by design: 0 is read as 1. What changed is that `config.lua` spells out that 0 is not an off switch, and the start-up validator says so too. The behaviour is unchanged and deliberate. |
>
> Nothing here was marked fixed on reading alone. "Held" means a guard was
> switched off and a named test went red; where that was not established the
> row says so.


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

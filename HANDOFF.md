# Crimson Arena — handover

A PvP arena resource for FiveM / Qbox. Author **John Allday**.

---

## 1. Where things are

| | |
|---|---|
| Working copy | `/home/user/arena-script` |
| Resource | `Crimson-Arena/` inside it |
| Branch | `claude/fivem-qbox-arena-script-vmoiqt` |
| Pull request | #1 on `XxNightLordxX/Arena-Script`, draft, open |
| Last pushed commit | `3fbdf06` |

**The shell's default directory is `/home/user/FIvem`, which is a DIFFERENT repository.**
Always `cd /home/user/arena-script` first. This has caused real mistakes.

Layout: `server/` (ammo, betting, match, lobby, stats, dispatch, main, util),
`client/`, `shared/arena.lua` (pure rules), `html/` (the admin tablet),
`locales/en.json`, `sql/`, `config.lua`, `config.weapons.lua`, `tools/`.

Load order is `fxmanifest.lua`; `server/util.lua` loads first and everything
else may call its globals without a guard.

---

## 2. Standing rules — do not change these without being told

These came from the owner directly. Several were re-stated after being missed.

- **Every commit message ends with the single line `Created By John Allday`.**
  Nothing else. No co-author trailers, no session links.
- **No tooling attribution anywhere in repository content** — not in code, not
  in comments, not in commit messages, not in PR titles or bodies. The work is
  John Allday's and reads that way throughout. The history was rewritten once
  to correct a single commit whose author field was not his, and a
  `filter-branch` backup ref holding 46 commits with foreign trailers was
  deleted. Every author in the log is now either `John Allday` or the two
  original `XxNightLordxX` commits. Keep it that way.
  (The branch name is pre-existing and is not content.)
- **Do not edit `sc-dispatch`, `sc-police` or `sc-ambulance`.** They are other
  resources, not in this repository. `Crimson-Arena/server/dispatch.lua` IS
  this resource's own file and IS editable.
- **Do not perform the owner's in-game checks for them.** Report what the code
  does; they test on the server.
- **`Config.Debug` stays ON.** Never suggest turning it off.
- **"Ensure friendly fire does not persist outside the arena"** — verbatim, a
  standing requirement.
- **Never `git add -A`.** Use explicit paths. Twice it swept scratch files into
  commits and broke CI.
- **Never `git checkout` to restore a file during mutation testing.** Copy the
  file to a backup first and restore from that. A checkout has destroyed work.
- **When an audit reports something as NOT fixed, verify with ~10 independent
  checks before acting.** Agents have been wrong in both directions.
- Review posture the owner asked for on each milestone: 5 quality checks,
  2 workflow checks, 1 debugger, 1 functions check, 1 exports test, 2 testers,
  and exploit testers on everything.

Two design decisions the owner made explicitly:

- **A fighter who walks out of a live round keeps their bet**, downgraded to a
  spectator bet at the spectator ceiling. This is deliberate — it is a
  demotion, not a forfeit. Do not "fix" it.
- **Crash coverage: write a row when a WEAPON is issued, not when it fails to
  come back. Weapons only** — rounds and supplies stay exit-only.

---

## 3. What the resource does, in one page

Two separate systems, often confused:

**The stash** holds the player's OWN belongings. On entry `stow()` moves
everything into `crimson_arena_<citizenid>`, an ox_inventory stash bound to
that character. On exit `restore()` clears the arena's kit and `handBack()`
returns the stash. Metadata passes through by reference, so a weapon's serial,
stolen flag, owner, registration, components and tint all survive the round
untouched. This part works.

**The owed-kit ledger** is about the ARENA's own property — the weapons and
ammunition it issues, which go into the player's pockets because they need
them to fight. At the exit the arena takes its kit back. The ledger exists for
when it cannot: the player disconnected, went to character select, or the
inventory was not loaded.

Three things stop the simple version always finishing in one go:

1. ox_inventory can refuse an `AddItem` (full inventory, weight). The stash
   keeps the items and a sweep retries every `returnRetrySeconds` (default 30).
2. At character select there is no loaded inventory — `ClearInventory` and
   `AddItem` both answer `nil`, which reads as success. Hence `stowedCount`,
   and why an empty stash read is never treated as a clean return.
3. Server ids are recycled. The stash is keyed to the CHARACTER, not the slot.

Weapons are tracked by the serial ox_inventory assigns, read back by diffing
the inventory after the item lands. Consumables are fungible numbers with a
"floor" (`heldBefore`) recording what the fighter walked in carrying, so the
exit can tell the arena's rounds from their own.

---

## 4. What was done in this session

All committed and pushed. Newest first.

| Commit | What |
|---|---|
| `3fbdf06` | `OwedKitIsSaved` no longer reports a successful SELECT as proof that writes work. Every write carries a callback; one nil answer while the database is reachable stops the tablet claiming the slate is durable. |
| `f8255ef` | The no-serial reclaim fallback no longer takes a weapon that carries a serial the arena did not issue — a stolen or registered gun is left alone. Also: the fungible debt chase no longer runs mid-round, so a debt cannot be settled out of the arena's own fresh loadout. |
| `b66d817` | Three betting fixes: the pot now goes to the character who staked rather than whoever holds the server id; `Settle` refuses a second payout for a match it already started paying; winning side bets are marked settled after the money moves, `owe`'s return is read, and `earnings` counts only what actually went somewhere. |
| `733d4cf` | Message-only. Corrects the previous commit's claim that the over-billing fix was untested — it does have a test; the harness had been wrong. |
| `0c8dea5` | The player is told when the arena takes its kit back. It was the one removal the resource did in silence. |
| `ddf8fcf` | The consumable debt is measured BEFORE the stash is handed back, so a player is no longer billed for rounds they already fired out of the stock just returned to them. |
| `bbd230e` | Doc corrections (four places still described one database table for the leaderboard only; three claims were wrong) and a dead locale key removed. |
| `cd5411c` | One database gate for the resource — `ArenaDbReady` / `ArenaDb` in `util.lua` — replacing two copies that had already drifted. `ArenaGetPlayer` wrapped in pcall. |
| `2fec9fe` | Four dead `ArenaAmmo` functions and the write-only `issued` table deleted; REFERENCE reconciled against source. |
| `db99516` | `reclaimStock` asked who owned the rows one line AFTER taking the goods, so it confiscated an innocent newcomer's own supplies on a recycled server id. |
| `61a49f4` | Stopped tracking the stripper's compiled `.pyc`. |
| `3d6cb0b` | The big one — see below. |

### The defect worth understanding

`3d6cb0b` fixed a guard that was **dead by construction**. `queueOwedKit`
refused to measure a player's pockets when `citizenid ~= liveId` — but both
callers reach that function only after establishing exactly that, and both
pass the departed character as `citizenid`. So the test was always true and
the consumables loop never ran once. Every round and every plate the arena
handed out still went free on the one path the ledger was written for.

The intent was right and the test was wrong: refuse when somebody **else** is
on the server id, not when **nobody** is. An empty id is the logout to
character select, where ox_inventory still has the departing character's
inventory loaded — so those counts are real and billing them is correct.

Six independent reviewers found this. It is the pattern to watch for in this
file: a guard whose condition is guaranteed by its own call sites.

---

## 5. The one uncommitted file

`Crimson-Arena/server/ammo.lua` carries the crash-persistence work the owner
chose ("write at issue, weapons only"). It parses and the design is complete:

- `markWeaponOut(record)` writes a row with `kind='out'` when a weapon is
  handed over, from inside `giveWeapon` — the single choke point every issue
  path goes through.
- `strikeWeaponOff(record)` deletes it when the weapon actually comes back,
  from inside `takeWeaponBack`'s `removeSlot`, gated on the RESULT of the
  removal rather than the attempt.
- `LoadOwedKit` promotes any `'out'` row that outlived the process into a real
  debt, because the only way such a row survives is that the exit never ran.
- Same `ledger_key` (`w:<serial>`), so a weapon is never in two states at
  once and no schema change is needed. `kind` already exists in the table.
- Both helpers are forward-declared locals near `giveWeapon` and assigned
  after the SQL and key builders. Verified with disassembly that neither
  leaks to `_ENV`.

**It is NOT proven**, so it is NOT applied. The harness that should
demonstrate a crash leaving a row and the next start reading it back was still
being fixed when work stopped.

The change is preserved as a patch:

    tools/pending-crash-persistence-weapons.patch

Apply it with `git apply tools/pending-crash-persistence-weapons.patch`,
finish the test, and only then commit. It was kept out of the branch so the
pull request contains nothing untested.

Open question on it: on a clean round, is every `markWeaponOut` matched by a
`strikeWeaponOff`? If not, an idle server slowly fills the table with rows for
weapons that were returned. That is the failure mode that matters most.

---

## 6. The test harnesses

In the repository at **`tools/harness/`**, with their own `README.md`. Each
loads the real `server/util.lua` and `server/ammo.lua` (or `betting.lua`)
under a fake FiveM environment and runs with `lua5.4`.

    cd tools/harness && for h in *.lua; do echo "--- $h"; lua5.4 "$h"; done

They caught several things that reading the code did not.

| File | Proves |
|---|---|
| `dbtest.lua` | With `Config.Database.enabled = false`, all eight public entry points run, nothing throws, and **zero** SQL statements are sent. |
| `ledger.lua` | The ledger records the same debt with the database off and on, billed to the departed character; and a SELECT-only database user now reads as "not saved". |
| `consumables.lua` | A logout mid-round records the debt (was 0, now 5); a stranger inheriting the server id loses nothing of their own. |
| `overbill.lua` | An honest player who fired their issue and owns the same items is billed 0, not 5. |
| `stolen.lua` | A stolen pistol keeps serial, stolen flag, owner, registration, components and tint through the whole door cycle, and is not confiscated by a serial-less arena record. |
| `launder.lua` | An old debt is not settled out of the arena's fresh mid-round issue. |
| `betting.lua` | A second settle pays nothing extra; the pot does not go to a character who took over the winner's server id. |

**Every fix in this session was proved by reverting it and re-running** — the
control run and the fixed run printing different numbers. Do that. Three times
a harness "passed" only because it was broken, and only the control revealed
it. `tools/harness/README.md` lists the specific traps already hit.

---

## 7. Gotchas that have cost real time

- **A vector is its own type in the CitizenFX Lua runtime.** `type(v)` answers
  `'vector3'`, never `'table'`. `type(x) == 'table'` on a coordinate rejects
  every real value. Use `Arena.IsPoint`. This bug recurred five times.
- **ox_inventory answers `nil`, not `false`, for an unloaded inventory.** The
  house helper `oxDid` treats `false` as refusal and `nil` as success — which
  is correct almost everywhere and WRONG at the exit, where a player at
  character select answers nil to everything. Ask the inventory what it holds
  rather than trusting a return value.
- **Removal by metadata filter is a filter, not an address.** `{ammo=...}`
  stops matching once a round is fired. Removal **by slot** is exact on every
  build; find the slot from `copiesOf`.
- **A nil inside a Lua table constructor makes the table undefined**, not one
  short. `{a,b,nil,d}` gives `#t == 4`, `ipairs` stops at 2, and FiveM's
  MessagePack packs it as a map rather than an array. Never pass a nil in a
  SQL parameter list — split the statement instead.
- **`x and nil or y` ALWAYS yields `y` in Lua.** This silently broke a test
  and cost an hour. Spell out the `if`.
- **`tools/strip_prod.py` deletes comments that do not "shout".** A block
  survives only if it contains a marker such as `NEVER `, `CANNOT `, `DO NOT`,
  `on purpose`, `deliberate`, `must not`. Every new comment must be checked
  **empirically** by copying the file, running
  `python3 tools/strip_prod.py --header "Crimson Arena" <copy>`, and grepping
  for the added lines. Reading the script is not enough — I have been wrong
  about this six times. Watch for a marker split across a line wrap
  (`DO` at the end of one line, `NOT` at the start of the next) — that does
  not count as a marker.
- **`config.lua` has a line-numbered header index** that must be remapped
  after any edit that changes line counts.

---

## 8. Verification routine used before every commit

```
cd /home/user/arena-script
for f in $(find Crimson-Arena -name '*.lua'); do luac5.4 -p "$f" || echo "FAIL $f"; done
node --check Crimson-Arena/html/app.js
python3 -c "import json;json.load(open('Crimson-Arena/locales/en.json'))"

# no local used before its definition (a leaked global is the symptom)
luac5.4 -l -l -p Crimson-Arena/server/ammo.lua | grep -oP '_ENV "\K[A-Za-z_]+' | sort -u
# every name in that list must be a genuine global

# production strip must keep the new comments and still parse
cp Crimson-Arena/server/ammo.lua /tmp/x.lua
python3 tools/strip_prod.py --header "Crimson Arena" /tmp/x.lua
luac5.4 -p /tmp/x.lua

# and the harnesses
cd <scratchpad>/harness && for h in *.lua; do lua5.4 $h; done
```

The `REFERENCE.md` function tables must match the source exactly, in source
order. Compare with:

```
grep "^function ArenaAmmo\." Crimson-Arena/server/ammo.lua | sed 's/^function \(ArenaAmmo\.[A-Za-z]*\).*/\1/'
```

---

## 9. Known open items, not yet fixed

Ordered by how much they matter.

1. **`handBack` can hand the same item twice.** If ox_inventory accepts the
   `AddItem` into the player but refuses the matching `RemoveItem` from the
   stash, `returned` still increments, the record is dropped, and the next
   sweep finds the leftover and hands it over again. The code prints a loud
   line about the copy being in both places but does not prevent it.
2. **`swapItems` is the only ox_inventory hook registered.** It covers drops,
   trunks, property stashes and giving to another player — but only for
   transfers that go through ox_inventory's swap path. Any other resource
   moving items with server-side `AddItem`/`RemoveItem` raises no hook and is
   unguarded mid-round. Worth confirming that "give to player" really routes
   through `swapItems` on the target build.
3. **Writes made during an oxmysql outage are never re-persisted.** There is
   no queue, no dirty set and no reconciliation, and `kitLoaded` blocks a
   re-read (correctly — a re-read would clobber memory with a stale table).
4. **`reclaimWeapons` does not consult `issuedOwner`** and fails open on a row
   with no citizenid. Partly mitigated by `f8255ef`, which now protects any
   copy carrying a serial.
5. **`stow`'s two rollback paths use bare `pcall`** and discard the result, so
   a silently refused `RemoveItem` leaves a duplicate in the stash that
   nothing knows about.
6. **A mid-connect player's floor is captured as 0 permanently.**
   `heldBefore` is written once per (match, src, item) and never re-read, so
   if the inventory was not loaded at issue the exit can take up to the full
   issued amount out of their own stock.
7. **`ArenaAmmo.Clear`'s refusal is permanent.** All three callers ignore the
   return and nothing retries, so `heldBefore`, `issuedOwner` and the issue
   tables leak for the life of the process for that match.
8. **A gun-game climber can end up unarmed for the rest of the round** — the
   respawn does not re-issue in ladder modes, and `settleTier` returns early
   when the tier is unchanged.
9. **With `stripOnEntry = false` the player is never warned** that anything
   leaving their pockets in the arena cannot be picked back up. They are
   warned on a stash failure, which is the same physical situation.
10. **`issueSpareRounds` gives nothing if the player already holds enough**,
    so with the door off they fight the round burning their own ammunition.
11. **Task #75 — "why the phone does not come back after a match" — is still
    open** and was never diagnosed.

---

## 10. Review agents

Fourteen were running when work stopped and all were killed; only one had
reported (stashes and the admin tablet — it found the two items at the top of
section 9 and otherwise found the stash system sound: citizen id is re-derived
server-side on every hand-back, the admin tablet is ACE-gated and re-checks on
every event, and the client-supplied stash in `QueueReturn` is inert).

Seven of a requested fourteen review agents were never launched: a second
functions check, 2 dead-code, 2 everything-works, 2 no-regressions, and
2 checking that the owner's stated wishes are still honoured.

When running agents against this codebase, tell them the working tree may be
dirty and to review what is on disk rather than HEAD — several reports have
been confusing because the file changed underneath them.

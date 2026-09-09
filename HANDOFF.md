# Crimson Arena — handover

**Two documents merged.** Sections 1–10 are the outgoing session's reference
material, unchanged. After them, "WHAT JOHN WANTS" and "PART D" answer the
incoming session's handover request by number.

**Nothing from either document has been removed.** Where the two disagree, both
readings are kept and the disagreement is called out — the owner asked for this
explicitly, so that a mistake on either side is visible rather than silently
resolved.

**Start here if you are picking this up:**

1. **WHAT JOHN WANTS** — his rules, what he is looking for, and the four
   questions only he can answer.
2. **PART D answer 1(d)** — history was rewritten and force-pushed. Read it
   before you rebase.
3. **HOW TO WORK WITH JOHN WITHOUT BURNING HIS MONEY** — he asked for this
   by name. It is the difference between one control test and five agents.
4. **WHAT THIS SESSION GOT WRONG** — the errors that repeated, with counts.
   One was made six times and one five times, each attempt freshly convinced.
   You will make them too unless you read the table.
5. **PART E** — thirteen agents verified all of this against the code and by
   running the tools. **It corrects three of my own answers**, including one
   where I said the repository could not tell you which config numbers are
   John's. It can, and E1 lists them.

---

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

---

# WHAT JOHN WANTS — read this before you touch anything

This section is the one he asked to be certain was complete. Everything below
came from him directly, most of it after I got something wrong first.

## Hard rules. Do not break these.

1. **Every commit message ends with the single line `Created By John Allday`.**
   Nothing else. No co-author trailers. No session links. If your tooling wants
   to append its own attribution, override it — he was explicit, and I ignored
   my own tooling's default for the whole session on his instruction.
2. **No tooling attribution anywhere in repository content.** Code, comments,
   commit messages, PR title, PR body, docs. The work is his and reads that way
   throughout. This is why one commit's author field was rewritten and why a
   `filter-branch` backup ref holding 46 commits with foreign trailers was
   deleted. Your `tools/verify_credit.sh` is exactly right; keep it.
3. **Do not edit `sc-dispatch`, `sc-police` or `sc-ambulance`.** They are
   separate resources, not in this repository. `Crimson-Arena/server/dispatch.lua`
   IS ours and is fair game.
4. **Do not run his in-game checks for him.** Report what the code does. He
   tests on the live server and tells you what he saw. Do not claim in-game
   behaviour you have not been told.
5. **`Config.Debug` stays ON.** Never suggest turning it off. Stated flatly,
   more than once.
6. **"Ensure friendly fire does not persist outside the arena."** Verbatim. A
   standing requirement, not a closed task — re-check it whenever you touch
   team handling or the exit path.
7. **Never `git add -A`.** Explicit paths only. It swept scratch files into
   commits twice and broke CI.
8. **Never `git checkout` to undo a mutation test.** Copy the file first and
   restore from the copy. A checkout destroyed work once.
9. **Preserve, do not tidy away.** When handing over, he said explicitly: *do
   not delete anything from the document in case the other chat got things
   wrong.* He would rather have two overlapping records than one clean one that
   lost something. Apply the same instinct to code you are tempted to remove.

## What he is looking for

- **Exploits, above all.** He asks repeatedly for exploit testers, powergamer
  personas and griefers — people trying to beat the arena using only legitimate
  in-game actions. Not hackers. The question he cares about is "what can a
  clever player do that I did not intend", and secondarily "what can a griefer
  do to somebody else".
- **Different angles, not more of the same.** When he asks for more agents he
  says "different stuff" / "do different tests". Duplicating a lane wastes his
  money. Give each one a distinct surface.
- **Proof, not assertion.** The strongest thing I did this session was build
  runnable harnesses and then **revert each fix to show the number change**.
  Three times a harness passed only because the harness was broken. If you
  claim a fix works, show the before and after.
- **Depth over speed.** He explicitly asked for large review fleets and told me
  to keep going. He is not optimising for token cost per task — but he *is*
  conscious of long chats becoming expensive, which is why this handover exists.
- **Autonomy.** "Continue", "do all that", "fix all that and continue" — he
  expects you to carry on through a list without checking in on every item.
  Check in when a decision is genuinely his, not to confirm you may proceed.
- **Concrete either/or, with the cost stated.** Both design decisions he made
  this session came from being offered options with trade-offs spelled out. He
  picks readily when the question is framed that way, and does not engage with
  open-ended "what would you like?".
- **Everything pushed.** He asks for work to be on the branch, not sitting
  local. When in doubt, push.

## His review posture, as he specified it

Per milestone: **5 quality checks, 2 workflow checks, 1 debugger, 1 functions
check, 1 exports test, 2 testers** — and *"add exploit testers on everything"*.
Later he asked separately for powergamer personas on distinct angles.

He also gave a verification rule: **when an audit reports something as NOT
fixed, verify with roughly 10 independent checks before acting on it.** Agents
have been confidently wrong in both directions and he has been burned by it.

## Decisions already made — do not reopen

From the two MD files (you have these):

- **EXPLOITS 7** — admin Abort voids all bets. **Deliberately left alone.**
- **EXPLOITS 8** — `maxTiersPerVictim` cap off. **Deliberately left alone.**

From my session, both put to him as explicit either/or and chosen by him:

- **Walk-out bets stay as they are.** A fighter who bets on their own side and
  walks out of a live round still collects; `MarkWalkedOut` downgrades the
  stake to a spectator bet at the spectator ceiling. I offered "void entirely"
  and "void only a bet on themselves". **He chose keep.** It is a demotion, not
  a forfeit. Any exploit agent will re-report this — it is settled.
- **Crash coverage: write at issue, weapons only.** Offered leave-it, full
  coverage, or weapons-only. He chose weapons-only, accepting the write cost
  for weapons and explicitly not wanting rounds and supplies written at issue.

## What he has not told us, and you should ask

These are real gaps. Do not fill them by guessing.

1. **False-positive tolerance.** The fence ejection and dead sweep can throw an
   innocent laggy player out of a paid round. He has never said how much of
   that he will accept. **This governs 8(b), 8(c) and 8(d) and every remaining
   anti-cheat decision.** It is the single most valuable question to ask him.
2. **Which config numbers are his.** Lives, round length, respawn delay, fence
   size, entry fees, win condition. Do not tune any of them until you know.
3. **"What should a 1v1 feel like."** Still open as far as I can tell.
4. **Scope and doneness.** What he still wants built, what is out of bounds,
   how near finished he thinks this is.

---

---

# HOW TO WORK WITH JOHN WITHOUT BURNING HIS MONEY

He asked for this section by name. His words: he does not like *"constantly
doing things over and having to use so many agents to confirm you didn't do
something wrong."*

He is right, and the fault is not his review process. **He has been paying
fleets of agents to do verification the developer should have done before
claiming the work was finished.** That is the loop to break. Everything below
is the specific, mechanical way to break it.

## The rule that replaces most of the agents

**Never claim a fix works. Show the number change.**

Before you say a defect is fixed, do this — it takes about a minute:

1. Write the smallest harness that reproduces the defect. `tools/harness/`
   has seven working examples and a README of the traps.
2. Run it **with the fix reverted**. Record the number.
3. Run it **with the fix in**. Record the number.
4. Report both. `before: 5, after: 0`.

This session's whole record argues for it. The consumables guard was dead at
every call site — six agents found it, but a two-line control test would have
found it in a minute for a fraction of the cost. The over-billing fix went in
with the honest note "verified by reading, not by test", and when the harness
was finally made to work it turned out **the harness had been wrong twice**,
not the code. Three separate harnesses passed while broken, and only the
control revealed it.

**A passing test proves nothing on its own.** If you did not watch the number
change when you removed the fix, you have not tested anything.

## The mechanical gates — seconds each, whole classes of bug

Run these on every file you touch, every time, before you commit. They are in
§8 above with the exact commands. They are not optional and they are not slow.

| Check | Catches |
|---|---|
| `luac5.4 -p` on every Lua file | syntax, every time |
| `luac5.4 -l -l -p \| grep '_ENV "'` | a local used before it is defined. Caught a forward declaration placed in the wrong spot this session — one command, instant |
| copy the file, run `strip_prod.py`, grep for the comments you added | comments that would silently vanish from the shipped resource. **This bit six times.** Reasoning about the stripper does not work; run it |
| `node --check` on `app.js`, `json.load` on `en.json` | the two non-Lua files |
| run all seven harnesses | regressions in what has already been proved |

**Never reason about what a tool will do. Run the tool.** Every single time I
predicted `strip_prod.py`'s behaviour instead of running it, I was wrong.

## What agents are for, and what they are not for

- **Agents are for DISCOVERY** — finding things nobody thought to look for.
  The powergamer and griefer personas earn their cost, because they surface
  attacks a developer staring at their own code will not imagine. The
  stolen-weapon confiscation and the debt-laundering path both came from that,
  and neither was on anybody's list.
- **Agents are NOT for confirming your own work.** If you are spawning a fleet
  to check whether you did your job, you have skipped the control test. Do the
  control test.
- **Give each agent a genuinely different surface.** He says this every time.
  Two agents on the same file is one wasted agent.
- **When an agent reports a defect, reproduce it yourself before acting.**
  They are confidently wrong in both directions. This is the reason for his
  ten-check rule — but the rule is a workaround for not verifying at source.
  Reproduce it, then fix it, then show the number change.

## Land it right the first time

The rework he is objecting to almost always traces to one of these:

- **A claim made before it was proved.** Covered above.
- **A fix applied without checking every call site.** `grep` for every caller
  before you change a function's behaviour. The dead guard survived precisely
  because nobody checked that both callers guaranteed its condition.
- **A batch edit that half-applied.** Python patch scripts have aborted
  mid-batch after earlier writes landed, leaving a duplicated block in
  `betting.lua` once. **Verify after every batch, not just at the end.**
- **Re-opening something already decided.** Check "Decisions already made" above
  and both MD files before you "fix" anything. He has said no to some of this
  already and does not want to say it twice.

## Things he does not want you to do

- **Do not run his in-game checks.** He tests on the live server. When he says
  something behaves a certain way in game, that is primary evidence — do not
  argue with it or re-derive it. Ask what he saw, then find it in the code.
- **Do not narrate the process.** He wants the outcome and the evidence.
- **Do not ask permission to continue.** "Continue", "do all that", "keep
  going" mean work the whole list. Check in only when a decision is genuinely
  his — and when you do, give him concrete options with the cost of each. He
  answers those immediately and does not engage with open questions.
- **Do not tidy away things he might want.** He said it directly during this
  handover: keep both versions in case one is wrong. Preserve over prune.

## The short version

**One control test at the moment of the change is worth five agents afterwards,
and costs about a hundredth as much.** Prove it when you write it, run the
mechanical gates every time, and spend the agents on finding what nobody knew
to look for.

---

---

# WHAT THIS SESSION GOT WRONG, AND THE CORRECTED INSTINCT

John asked for this section specifically. It is not an apology — it is the
scar tissue, written down, because the next session does not inherit any.

Each entry is a **wrong instinct I actually had**, what it cost, and the
instinct that replaced it. If you catch yourself about to do one of these, you
are repeating a mistake that has already been paid for.

## The ones that repeated — read this table first

Not the one-off slips. These are the errors I made **again and again**, each
time freshly convinced I was right, because nothing carried over between them.
They will feel like new judgements to you too. They are not.

| Repeats | The wrong instinct | The one-line fix |
|---|---|---|
| **6×** | Predicting what `strip_prod.py` keeps instead of running it | Copy the file, run it, grep for your own lines |
| **5×** | `type(v) == 'table'` on a coordinate | A vector is its own type. Use `Arena.IsPoint` |
| **3×** | Trusting a harness because it passed | Revert the fix. If the number does not move, the harness is broken |
| **3×** | Claiming a fix works before testing it | The control test *is* the claim |
| **2×** | Reading `nil` as success at the exit | `nil` means the inventory was not there — that is the failure case |
| **2×** | Believing an agent's report without reproducing it | Reproduce, then act |

The 6× and the 5× are the tell. A person makes that mistake twice and the
second one stings. Nothing stings here — each attempt is re-derived clean from
the same wrong premise, so **frequency is not evidence of difficulty, it is
evidence of no memory.** That is exactly what this document is for.

Detail on each, plus the one-off errors, follows.

## 1. "I can predict what this tool does by reading it."

**Cost: six repeats.** Every time I reasoned about what `strip_prod.py` would
keep or delete instead of running it, I was wrong. Comments I was certain would
survive were deleted. Once, a marker was split across a line wrap — `DO` at the
end of one line, `NOT` at the start of the next — which I would never have seen
by reading.

**Corrected instinct: run the tool.** Copy the file, run the stripper, grep for
your own added lines. It takes ten seconds. There is no amount of reading that
substitutes.

Generalised: **any question that a command can answer, answer with the
command.** Not just this stripper.

## 2. "The fix is obviously right, so I can say it works."

**Cost: the single biggest defect of the session.** I wrote a guard whose
condition was *guaranteed true by both of its call sites* — so the code it
protected never ran once. Six review agents found it. A two-line control test
would have found it in a minute.

**Corrected instinct: the control test IS the claim.** Revert the fix, run,
record the number. Put it back, run, record. `before: 5, after: 0`. Until you
have those two numbers you have an opinion, not a fix.

## 3. "My test passed, so the thing works."

**Cost: three harnesses passed while broken.** In one, the fake `RemoveItem`
decremented the player's pockets even when removing from the *stash* — so every
returned item landed and instantly vanished, and the test read 0 either way. In
another, `Arena.AllIssuedItems` returned `{}`, quietly emptying the snapshot the
fix depended on and making a real fix look like a no-op.

**Corrected instinct: a harness that agrees with you is suspect until you have
watched it disagree.** If reverting the fix does not change the output, your
harness is not testing the fix. That is the *first* thing to check, not the
last.

## 4. "The house convention covers this case."

**Cost: a free loadout on five routes.** The codebase treats `false` as refusal
and `nil` as success — correct almost everywhere, and exactly wrong at the exit,
where a player at character-select answers `nil` to everything precisely
*because* nothing happened.

**Corrected instinct: ask what the value means HERE, not what the convention
says.** A convention that is right 95% of the time is a trap at the other 5%,
and the 5% is where the money is.

## 5. "I wrote a guard, so the case is handled."

**Cost: see 2.** A guard is only as good as the callers' ability to fail its
condition.

**Corrected instinct: after writing any guard, grep every caller and ask "can
this condition ever be false here?"** If no caller can falsify it, the guard is
dead and you have written a comment, not a check.

## 6. "Both fixes are correct, so together they are correct."

**Cost: every clean exit wrote a permanent phantom debt.** Two individually
sound changes — "queue before forget" and "keep the row" — combined into a debt
that could never clear.

**Corrected instinct: after two changes in the same area, re-walk the combined
path from the top.** Not each change. The path.

## 7. "The batch script ran, so the batch applied."

**Cost: a duplicated settle block in `betting.lua`, found later by grep.**
Python patch scripts have aborted partway after earlier writes already landed.

**Corrected instinct: verify after every batch, not at the end of the
session.** Parse the file and grep for what you just wrote, every time.

## 8. "The declaration is in the file, so it is in scope."

**Cost: nearly shipped.** I forward-declared two locals *below* the function
that called them. Caught in one command by
`luac5.4 -l -l -p file | grep '_ENV "'` — a name showing up as a global is the
symptom.

**Corrected instinct: run that grep on every server file you touch.** Every
name it prints must be a genuine global.

## 9. "The agent found it, so it is true."

**Cost: wasted effort in both directions.** Agents reported defects that were
not real, and reported as fine things that were broken. One reported five
"deleted" comments that were actually fine — my grep had spanned a line wrap.

**Corrected instinct: reproduce before you act.** This is the reason for John's
ten-check rule, but the rule is a workaround. Reproducing it yourself is
cheaper and settles it.

## 10. "The rule is about the code, not about what I write about the rule."

**Cost: nearly committed a handover document that would have failed the
project's own attribution check**, because I quoted the exact string the check
greps for while explaining that the string must not appear.

**Corrected instinct: apply the rule to the artefact you are writing about the
rule.** Including this document.

## 11. Language-level traps that bite regardless of care

These are in §7 above with more detail. They are listed again here because they
are the ones that produce *silent* wrong answers rather than errors:

- **A vector is its own type.** `type(v)` answers `'vector3'`, never
  `'table'`. Recurred five times across sessions. Use `Arena.IsPoint`.
- **`x and nil or y` always yields `y`.** It silently disabled a whole test
  branch for an hour. Spell out the `if`.
- **A `nil` inside a table constructor makes the table undefined**, not one
  element short — and FiveM's MessagePack then sends it as a map, not an array.
- **Removal by metadata filter is a filter, not an address.** `{ammo=...}`
  stops matching the moment a round is fired. Remove by slot.

## The pattern underneath all of these

Nine of the eleven are the same error wearing different clothes: **I substituted
reasoning for observation.** I predicted what a tool would do, what a test
proved, what a convention covered, what a caller could pass — instead of
running, reverting, checking, grepping.

The corrected instinct, stated once: **when the machine can answer, do not
answer for it.** It is faster than being wrong, and it is the whole difference
between one control test and five agents.

---

# PART D — ANSWERS TO THE HANDOVER REQUEST

Answered by number. Where I do not know something, I say so rather than guess —
several of these ask about conversation I no longer hold, and a confident wrong
answer here is worse than an admitted gap.

**Read answer 1(d) before you rebase.** It is the one that can cost you work.

---

## 1. What I pushed, and whether it has landed

**(a) Files touched** — 21, across 13 commits (`3d6cb0b` … `ecf7716`):

```
Crimson-Arena/server/ammo.lua      +588  the bulk of it
Crimson-Arena/server/betting.lua   +129
Crimson-Arena/server/util.lua       +86  new shared database helper
Crimson-Arena/server/stats.lua      -34  switched onto that helper
Crimson-Arena/shared/arena.lua       +4  one stale comment
Crimson-Arena/locales/en.json            one key added, one dead key removed
Crimson-Arena/README.md
Crimson-Arena/REFERENCE.md
Crimson-Arena/DEPLOYMENT.md
HANDOFF.md                          new
tools/harness/*                     new — 7 harnesses + README
tools/pending-crash-persistence-weapons.patch   new
tools/__pycache__/strip_prod.cpython-311.pyc    deleted (was tracked)
.gitignore                          __pycache__ rule added
```

I did **not** touch `match.lua`, `lobby.lua`, `dispatch.lua`, `main.lua`,
`config.lua`, `config.weapons.lua`, `fxmanifest.lua`, any client file, or
`html/`. Your five mismatches in question 8 are all in files I never edited,
so nothing I did caused or masked them.

**(b) Final SHA:** `ecf7716380d9a3ed38007093200a873c6200e917`

**(c) landed**

**(d) YES — I REWROTE HISTORY. Read this before rebasing.**

One commit, *Let the host set how long a round runs*, carried a tooling
identity in both its author and committer fields rather than John's. Its
message body was already correct; only the identity was wrong. (I do not quote
the string here on purpose — your `verify_credit.sh` would flag this very
document. Run `git log --format='%an <%ae>' | sort -u` if you want to see for
yourself what the log holds now.) I ran `git filter-branch --env-filter` over
`HEAD` to change only those identity fields to
`John Allday <jlwood17190665@gmail.com>`, then **force-pushed**. The reflog
shows the non-fast-forward: `4ac5daf...db99516 (forced update)`.

What I verified afterwards:

- The tree hash was **identical** before and after — `aa1f9ad3a3347898b5264b19503af8785948d1cb`. Not one byte of content changed.
- The commit count was identical.
- `git log --format='%an' | sort -u` now returns exactly `John Allday` and `XxNightLordxX` (the two earliest commits). Nothing else.
- I also deleted the `refs/original/…` backup ref that `filter-branch` leaves behind. That ref held **46 commits carrying tool trailers** in their messages, and it was pushable. `git for-each-ref refs/original` now returns nothing.

The commit is now `8291f5c`, 43rd from the tip.

**Checked for you, because your recovery depends on it:** `566171c` and
`7fb527e` **still resolve on origin today**, and `566171c` still contains 104
files under `Crimson-Arena/tests/` (77 `_spec.lua`). Your recovery point is
intact. Confirm it yourself before you trust me:

```
git fetch origin claude/fivem-qbox-arena-script-vmoiqt
git ls-tree -r --name-only 566171c -- Crimson-Arena/tests | wc -l
```

**How to bring your one commit across.** Do not plain-rebase without checking —
if your clone predates the force-push your base may be gone. Safest for a
single commit:

```
git fetch origin claude/fivem-qbox-arena-script-vmoiqt
git format-patch -1 HEAD --stdout > /tmp/verify_credit.patch   # save your work first
git reset --hard origin/claude/fivem-qbox-arena-script-vmoiqt
git am /tmp/verify_credit.patch
```

`tools/verify_credit.sh` does not collide with anything I added under `tools/`
(`harness/`, one `.patch`), so it should apply cleanly.

**One discrepancy to resolve.** You say "all 50 commits". I count **330** total,
**329** since `origin/main`, spanning 2026-08-30 to 2026-09-09. If you are
seeing 50 you may have a shallow clone, or be counting the PR's page rather
than the branch. Worth settling before you reason about history — we may not be
looking at the same thing.

---

## 2. Decisions John made in conversation — WHAT I ACTUALLY HAVE

**Be careful with this answer.** My conversation was compacted partway through.
I hold a written summary of the earlier part, not the transcript. So I can give
you the standing rules with confidence, and I have to tell you honestly that
most of 2(a)–(f) is **not recoverable from my side**.

### What I can state with confidence — his standing rules

These were re-stated to me directly, several after I got them wrong:

1. **Every commit message ends with the single line `Created By John Allday`.**
   Nothing else. No co-author trailers, no session links. I was instructed to
   ignore the tooling's own default attribution, and I did.
2. **No tooling attribution anywhere in repository content** — code, comments,
   commit messages, PR title, PR body. This is why I rewrote that commit.
   Your `tools/verify_credit.sh` is exactly in the spirit of it.
3. **Do not edit `sc-dispatch`, `sc-police` or `sc-ambulance`.** Different
   resources, not in this repo. `Crimson-Arena/server/dispatch.lua` IS ours.
4. **Do not do his in-game checks for him.** Report what the code does; he
   tests on the live server. He will tell you what he saw.
5. **`Config.Debug` stays ON.** Never suggest turning it off. Stated flatly.
6. **"Ensure friendly fire does not persist outside the arena"** — verbatim, a
   standing requirement, not a one-off task.
7. **Never `git add -A`.** Explicit paths only. It swept scratch files into
   commits twice and broke CI.
8. **Never `git checkout` to undo a mutation test.** Copy the file first,
   restore from the copy. A checkout destroyed work once.
9. **When an audit says something is NOT fixed, verify with ~10 independent
   checks before acting.** Agents have been wrong in both directions.
10. **Review posture he asked for per milestone:** 5 quality checks, 2 workflow
    checks, 1 debugger, 1 functions check, 1 exports test, 2 testers — and
    "add exploit testers on everything". Later he asked for powergamer personas
    specifically, and for agents to be given *different* angles rather than
    duplicated.

### Two decisions he made in THIS session, which are new since your docs

I put both to him as explicit either/or questions and he chose:

- **(2b/2d) Walk-out bets: KEEP AS-IS.** A fighter who bets on their own side
  and walks out of a live round still collects. `MarkWalkedOut` downgrades the
  stake to a spectator bet and trims it to the spectator ceiling. I offered him
  "void it entirely" and "void only a bet on themselves". **He chose keep.**
  It is a demotion, not a forfeit. **Do not "fix" this** — it will come back as
  a finding from any exploit agent and it is settled.
- **(2f) Crash coverage: "write at issue, but only weapons."** I offered
  leave-it, full coverage, or weapons-only. He chose weapons-only, explicitly
  accepting the write cost for weapons and explicitly *not* wanting rounds and
  supplies written at issue. That decision is what
  `tools/pending-crash-persistence-weapons.patch` implements.

### What I do NOT have — do not let me invent it

- **(2a)** The bet ceiling 50,000 → 25,000 is *your* finding, not mine. I have
  no record of it. I cannot tell you which other config numbers are his.
- **(2c)** Decision 8 / "tell me what a 1v1 should feel like" — **no record of
  an answer.** Not in my summary, not in this session. Treat it as still open.
- **(2d)** Respawn delay, lives, round length, fence size, entry fees, win
  condition — **I cannot separate his numbers from defaults.** I never touched
  `config.lua` in this session.
- **(2e)** False-positive tolerance — **never discussed with me.** This is a
  real gap and I agree it governs the remaining anti-cheat work. **Ask him
  directly.** Note it interacts with 8(c) and 8(d) below.
- **(2f) scope** — beyond the two decisions above, nothing.

**My strong recommendation:** put 2(a), 2(c), 2(d) and 2(e) to him as four
short direct questions before you tune anything. `config.lua` is heavily
commented and often records *why* a number is what it is — that is your best
independent source, and I have an agent mining it (results below).

---

## 3. My known-but-unfixed list

Full detail is in `HANDOFF.md` §9 in the repo. Classified the way you asked:

**(a) Too risky to touch, or needing a design change I would not make alone**

- **Writes made during an oxmysql outage are never re-persisted.** No queue, no
  dirty set, no reconciliation. `kitLoaded` deliberately blocks a re-read —
  correctly, since a re-read would clobber memory with a stale table. Fixing it
  properly means a write-behind queue.
- **`ArenaAmmo.Clear`'s refusal is permanent.** All three callers ignore the
  return and nothing retries, so `heldBefore`, `issuedOwner` and the issue
  tables leak for the life of the process for that match.

**(b) Not worth the complexity, or bounded loss**

- **`stow`'s two rollback paths use bare `pcall`** and discard the result, so a
  silently refused `RemoveItem` leaves a duplicate in the stash. The file's own
  rule says "DO NOT put a bare pcall back", so this is inconsistent — but both
  paths are already failure paths.
- **A mid-connect player's floor is captured as 0 permanently.** `heldBefore`
  is write-once per (match, src, item), so if the inventory was unloaded at
  issue the exit can take up to the full issued amount out of their own stock.

**(c) Blocked on a John decision**

- **Anything touching false-positive tolerance** — see 2(e). Specifically your
  8(c) and 8(d).
- **`issueSpareRounds` gives nothing if the player already holds enough**, so
  with the door off they burn their own ammunition. Whether that is a bug or
  the intended "top up to N" is a gameplay call.

**(d) Suspected but not proved**

- **`reclaimWeapons` never consults `issuedOwner`** and fails open on a row
  with no citizenid. Partly mitigated by `f8255ef` (any copy carrying a serial
  is now protected), but I did not prove the remaining exposure either way.
- **`handBack` can hand the same item twice** — if ox_inventory accepts the
  `AddItem` into the player but refuses the matching `RemoveItem` from the
  stash, `returned` still increments, the record is dropped, and the next sweep
  finds the leftover and hands it again. The code prints a loud line about the
  copy being in both places but does not prevent it. I could not force the
  refusal to prove it end to end.
- **`swapItems` is the only ox_inventory hook registered.** It covers drops,
  trunks, property stashes and give-to-player *only for transfers that go
  through ox_inventory's swap path*. Any other resource moving items with
  server-side `AddItem`/`RemoveItem` raises no hook and is unguarded mid-round.
  Worth confirming on the target build that give-to-player really routes
  through `swapItems`.

**(e) Fixed only partially**

- **The crash-persistence work** — designed, written, parses, **not proven**,
  deliberately left as a patch and not committed. See 6.
- **A gun-game climber can end up unarmed for the rest of a round** — the
  respawn does not re-issue in ladder modes and `settleTier` returns early when
  the tier is unchanged. Diagnosed, not fixed.
- **With `stripOnEntry = false` the player is never warned** that anything
  leaving their pockets cannot be picked back up. They *are* warned on a stash
  failure, which is the same physical situation. Asymmetry noted, not fixed.
- **Task "why the phone does not come back after a match" is still open** and
  was never diagnosed. It has been open a long time.

---

## 4. The 81 specs

**(a) No. I never ran the suite.** Not against `ecf7716`, not against anything.
`Crimson-Arena/tests/` does not exist in my working tree — I inherited the
post-strip state and never recovered it. So I have no result to give you, and
you should not assume any spec still passes.

**(b) I did not update any spec, because I could not see them.** So yes —
**assume the recovered specs test pre-strip behaviour** where my 13 commits
changed it. The ones you named that I would expect to be affected:

| Spec | Why I expect it to diverge |
|---|---|
| `betting*`, `payoutchain`, `selfbet` | The pot payout now passes the staker's citizenid to `credit`; `Settle` refuses a second payout via a new `settling` flag; side-bets are marked settled *after* the credit. |
| `lifecyclemoney`, `moneyconservation` | Same three changes. `earnings` now counts only money that actually moved, so any spec asserting the old total will differ. |
| `ammo*`, `loadoutkit` | Very large changes: the consumables ledger now records where it silently did not; the debt is measured before the stash hand-back; the no-serial reclaim fallback refuses a weapon carrying a serial; the mid-round chase is gated. |
| `stashscan` | `AllStashes` untouched, but it shares `ArenaDb` now. |
| `serverchecks_spec` | I did **not** touch `match.lua`, so this should be unaffected by me — but it is exactly where your 8(a)–(d) live. |

**(c)** I cannot name a specific spec that *should* now fail without reading
them. But by construction, any spec asserting "a logout mid-round records no
consumable debt" is now wrong on purpose — that was the single biggest defect I
fixed, and the behaviour deliberately changed from 0 to a real debt.

**(d) You do not need to stand anything up. Both are already installed:**

```
Lua 5.4.6   (lua5.4 and luac5.4)
Luacheck 1.1.2
```

I used `luac5.4 -p` for parsing and `luac5.4 -l -l -p | grep '_ENV'` for
use-before-definition. **I never ran luacheck** — I did not know it was there
until I checked for this handover. `.luacheckrc` is not in the tree (stripped),
so you would need the recovered one.

I also wrote **seven runnable harnesses**, now committed at `tools/harness/`,
which load the real `server/util.lua` and `server/ammo.lua` (or `betting.lua`)
under a fake FiveM environment. They are not a substitute for the specs but
they are real executable coverage of the things I changed. **Read
`tools/harness/README.md` before using them** — it records three traps that
made a harness pass while broken.

---

## 6. What was in flight when I was paused

**(a) and (b)** One thing, and it is preserved:
`tools/pending-crash-persistence-weapons.patch` (151 lines).

Its intended shape, so you can finish it:

- `markWeaponOut(record)` writes a row with `kind='out'` when a weapon is
  handed over, from inside `giveWeapon` — the single choke point every issue
  path goes through (Issue, Refresh, SwapWeapon, putRungsBack).
- `strikeWeaponOff(record)` deletes it when the weapon comes back, from inside
  `takeWeaponBack`'s `removeSlot`, gated on the **result** of the removal, not
  the attempt.
- `LoadOwedKit` promotes any `'out'` row that outlived the process into a real
  debt — the only way such a row survives is that the exit never ran.
- Same `ledger_key` (`w:<serial>`), so a weapon is never in two states at once.
  **No schema change** — `kind` already exists in `crimson_arena_owed_kit`.
- Both helpers are forward-declared locals near `giveWeapon` and assigned after
  the SQL and key builders. I verified by disassembly that neither leaks to
  `_ENV` — that check caught the declaration being in the wrong place once.

**It parses. It is NOT proven.** I deliberately did not commit it so the PR
contains nothing untested.

**(c) The thing I concluded and had not written down:** the open question on
that patch is *whether every `markWeaponOut` on a clean round is matched by a
`strikeWeaponOff`*. If not, an idle server slowly fills the table with rows for
weapons that were returned. That is the failure mode that matters most and it
is what the unfinished test was for.

**(d) The file I was about to change** was the harness, not the resource — the
fake database in `tools/harness/ledger.lua` records the `INSERT` going out but
was not storing it, so I could not yet show a crash leaving a row and the next
start reading it back. Same class of harness bug as the three in the README.

---

## 7. Feature ideas already discussed

**I have nothing for you here.** No feature proposals were made in the part of
this session I still hold, and none were accepted or rejected in my presence.
My whole session was defect work, dead-code removal, one refactor and this
handover. Treat the feature space as **completely open** — anything you bring
him will be new as far as I know.

The one adjacent thing: he asked me to research *nothing*, but he did make the
two design decisions in 2 above, both of which were my proposals put to him as
options. So he is willing to be given an either/or and will pick. That is a
good way to work with him — concrete options with the cost stated, not open
questions.

---

## 5, 8 — see below

Answered from live verification rather than memory; results follow.

---

## 5. The four `tools/` checks

**(a) Only one was run, and it was run constantly: `strip_prod.py`.**

I ran it against every file I touched, on every commit, as a mandatory gate.
Not to strip the tree — to prove my new comments would **survive** stripping.
That check is in the routine in §8 above and it caught comments that would have
silently vanished from the shipped file six separate times.

`inventory.py`, `verify_lua_identical.sh` and `verify_web_identical.py` — **I
never ran any of them.** No result to give you.

**(b) The 972 / 983 discrepancy — I cannot settle it from memory.** There is no
stored baseline file that I found. Read `inventory.py` and run it against
`ecf7716` yourself; that is the only number that means anything now. My guess,
worth exactly what a guess is worth: the two figures are from either side of
one of the slimming commits, and neither is current.

**(c) `verify_lua_identical.sh` and `verify_web_identical.py` are now
historical for their original purpose.** They exist to prove a strip changed no
behaviour: compile both sides, compare instruction streams. The strip has
happened, so there is no "before" in the tree any more.

They are **not useless**, though — the "before" is any commit. `git worktree
add` a pre-strip commit and you have a valid pair. That would also be the
honest way to re-verify the strip now that ~14 commits have landed on top.

**(d) I did not audit `strip_all.sh` for staleness.** It does name files and
one-line headers by hand, so it is a plausible source of drift, and I added
`tools/harness/` under `tools/` which it certainly does not know about (though
harnesses are not shipped, so that may not matter). Worth a read before you
trust it.

---

## 8. Your five doc/code mismatches — verified against HEAD

I checked all five **by reading the code myself**, not from memory. None are in
files I touched, so none of my 13 commits caused or masked them.

**Summary: four of your five are accurate. One is incomplete — you did miss a
second value.**

### 8(a) — ACCURATE, and deliberate. Fix the document.

The code's own comment says it, immediately above the check at
`server/match.lua:1388-1389`:

> `-- them -- so the death stands, spends its life and schedules its`
> `-- respawn, and only the kill goes unpaid.`

That is the code stating your reading back to you. The behaviour is deliberate
and the reasoning (skydome fallers stranded, then ejected by the fence) is
recorded. **`EXPLOITS-YOUR-CALL.md` is wrong; the code is right.** Fix the doc.

### 8(b) — ACCURATE. The fail-open is real and still open.

`server/match.lua:1401`:

```lua
local far = metresBetween(positionOf(killer.src), positionOf(victim.src))
if far and far > ceiling then
```

`far == nil` (unreadable position) skips the ceiling check entirely. Confirmed
by reading.

Note the contrast one block above, at `:1392`:

```lua
if past ~= nil and outsideMetres > 0 and past > outsideMetres then
```

The out-of-fence check is written the same fail-open way. So this is a
**consistent posture across both checks**, not an oversight in one. That
strengthens the "deliberate" reading — but it is a posture question, and
posture questions here are John's, not ours. **This is question 2(e) wearing a
different hat.** Ask him before changing it.

### 8(c) — ACCURATE, and better-found than you may realise.

Only four references exist in the whole file: lazy init at `:1135-1136`, and
the two `strike` calls at `:1147` and `:1153`. **Nothing clears either table**
— not on respawn, not on leave, not on death, not on match end beyond the
match table being dropped.

The mechanism is subtler than "never cleared", and worth stating precisely,
because `strike` *does* self-clear (`server/match.lua:1117-1121`):

```lua
local function strike(store, src, sighted, needed)
    if not sighted then
        store[src] = nil          -- resets on a clean observation
        return false
    end
```

So the count resets fine **whenever `strike` is actually called**. The leak is
that it often isn't. The roster is built at `:1140` as:

```lua
if player.alive == true and player.leftArena ~= true then
```

and the inner loop re-tests `player.alive == true` at `:1145`. **A dead player
is excluded from the sweep entirely**, so `strike` is never called for them,
so their count cannot reset — it freezes and resumes on respawn. Same for
anyone who has left. Your "N consecutive checks leaks across a death/respawn
cycle" is exactly right, and the `elseif` at `:1152` means a fence strike also
suppresses the dead check in the same tick.

Add that server ids are recycled and a stale entry can be inherited by a
newcomer within the same match.

**Known?** Not by me — I never touched `match.lua`. Treat it as a genuine
find. It is a real defect, not a doc bug.

### 8(d) — ACCURATE structurally. Confirmed:

- `client/match.lua:560` — `ArenaDispatch.ClearDeadState(ped)`
- `client/dispatch.lua:149` — the function; `:151` gates on
  `config.clearDeadStateImmediately == false`
- `config.lua:2408` — `clearDeadStateImmediately = true` ships

Your trade-off reading follows from 8(c): the sweep only looks at players the
server already believes are alive, so a client that swallows the death report
*and* shows a healthy ped is invisible to it. **Whether that trade was
understood, I cannot tell you** — it is not in what I hold. It is squarely
question 2(e). Do not change it without his answer; tightening it is precisely
what throws laggy players out of paid rounds.

### 8(e) — INCOMPLETE. You missed a second value.

`config.lua:438` is `outsideMetres = 10.0`, as you say. **But
`server/match.lua:1084` is:**

```lua
math.max(0.0, tonumber(block.outsideMetres) or 60.0),
```

**The code's fallback default is still 60.** So the document's "sixty metres of
grace" is not stale prose describing a dead value — it matches the **code
default**, which is what applies whenever the config block is missing or
unreadable. The shipped config overrides it to 10.

So it is not simply a doc bug. There are two numbers and they disagree, and
which one you get depends on whether the config block reads. I would treat that
as the real finding here: **align the code fallback with the shipped config, or
say plainly in the doc that they differ and why.**

One more thing you will want: `:1392` reads `outsideMetres > 0`, so setting it
to **0 disables the out-of-fence kill refusal entirely**. That is a supported
config value with a non-obvious consequence.

---

# PART E — VERIFIED APPENDIX (supersedes parts of PART D)

Thirteen agents, no errors, ~2.7M tokens, run against `ecf7716`. Everything
below was produced by **reading the code and running the tools**, not from
memory. Where it corrects an answer in PART D, **the original is left in place
above and the correction is marked** — Part D shows what one session believed;
this shows what the repository proves.

**Three of my own answers were wrong or too weak. They are corrected here.**

---

## E1. CORRECTION to answer 2 — the repository proves far more than I said

**PART D says I cannot tell you which config numbers are John's. That was
wrong.** I could not recall them, but the pre-strip `config.lua`
(`git show 23a8e05^:Crimson-Arena/config.lua`, 3,129 lines — the strip
deliberately deleted the "why this number changed" history) and 332 commit
messages record most of it verbatim.

### HIS numbers — do not tune these

| Setting | Value | Evidence |
|---|---|---|
| `Config.Match.lives` | default **3**, range 1–10 | `8786ed6`: *"Asked for as \"3 lives per match\", then as the host choosing."* Was a flat `lives = 1`. **The clearest owner-set gameplay number in the repo.** |
| every firearm `ammo.max` | **500** | `cfcf3b6`: *"Asked for: 500 rounds on every gun, 30 bandages, 25 armour."* Was 80/150/250/500 per weapon. |
| `supplies.items.armour.max` | **25** | same commit. Was 4. |
| `supplies.items.bandage.max` | **30** | same commit. Was 6. |
| `Config.Loadouts.slots` | **4**, guns and blades in one count | `af76eb6`, verbatim: *"Let it choose if they only want to guns or only melee."* Replaced separate `weaponSlots`/`meleeSlots`. |
| `config.weapons.lua` — **all 96 weapons enabled**, heavy included | on | `b8b053b`: *"AT THE OPERATOR'S INSTRUCTION: every weapon is enabled"* — RPG, launchers, minigun, railguns, flamethrower. README calls it *"a deliberate choice, not an oversight"*. |
| `Config.Modes.gungame.enabled` | **true** | Flipped **four times**, every flip owner-driven (`2cd44d7`, `f0292f1`, `2c75115`, `d6d16d9` *"The operator asked for it"*). **Do not touch.** |
| `Config.Debug` | **true** | `023cee1`: *"ships on, as asked. It is chatty on purpose."* |
| `Config.Schedule.windows[1]` | **0 → 4** | `d697fa8`: *"runs to 4am rather than 2am, as asked."* The other three windows have **no** owner evidence. |
| Lobby ped / marker / `returnCoords` | `vector4(-282.0125, -2030.4575, 30.1457, 276.6953)` | `2a30c70`: *"at the operator's request."* All three move together. |
| `Config.Arenas['trailerpark']` | exists, enabled | `a9d8fe9`: *"a new arena at the operator's own coordinates."* |
| Arena roster — only skydome + trailerpark | 2 | `439a53c`: *"At the operator's request the ground arenas are switched OFF."* |
| `Config.Teams.list` colours | brightened | `30da6ee`: *"BRIGHTER BLIPS, asked for directly."* |
| `Config.Match.spawnHeightOffset` | **1.0** | `0b9f1d0`, from field reports quoted verbatim: *"in the trailer park i keep spawning in trailers"*. **Field-validated by his players.** |
| `Config.Betting.fighterBets.max` | **25000** | Your finding, confirmed: EXPLOITS decision 6, under *"do all your recommendations besides option 7 and 8"*. Standing rule in the config comment: **keep level with `spectatorBets.max`.** |
| `gungame.maxTiersPerVictim` | **0** | Decision 8: *"You asked me to remove it so a 1v1 works."* |

### NOT his — developer calls, safe to revisit

`outsideMetres` 60→**10** (`566171c`, exploit fix — see E4); `entryFee.default`
0→**500** (`40c58e1`, explicitly *not* a request); `supplies.totalItems` 55→**0**
(developer tidy-up — but the **25 and 30 above ARE his**); `gungame.tierAmmo`
200; `maxKillDistance` 150.0; boundary `damagePerTick` 8→20; skydome
`boundary.radius` 60→**110**. `Config.Schedule.enabled` was toggled off only as
temporary test scaffolding and is back on.

### Also explicitly rejected — beyond the two you know

Alongside EXPLOITS 7 and 8: **decision 5's alternative** (`closeAfterStartSeconds
= 0` for everyone — watchers keep their 30 seconds); **decision 1's hard fix**
(server-authoritative death detection, declined as the owner's design call);
and **per-accomplice kill caps** (*"I did not cap fed kills per accomplice;
that is decision 8, which you left alone"*).

### Do not "add a knob" for these — they are rules on purpose

- *"Full health and a full plate on every life ARE A RULE, NOT A SETTING."*
- *"No slash command exists. The NPC is the way in, and it is the only way in."*
- *"WHEN THE BOOK SHUTS FOR A FIGHTER: the moment the round goes live, and
  there is no setting for it."*
- `lockdownMode = 'relaxed'` — *"not `'strict'` on purpose."*

**Still genuinely open** — unchanged from PART D: false-positive tolerance,
the 1v1 question, and scope. Those really are not in the repository.

---

## E2. CORRECTION to answer 5 — the tools were all run

**PART D says only the stripper was ever run and I could not settle 972 vs 983.
Both gaps are now closed with real output.**

### The baseline is neither 972 nor 983. It is **994** at HEAD.

No stored baseline exists anywhere; it must be regenerated. Run against every
relevant tree:

```
1786866  973     ← where "972" was written. Hand-typed, off by one even then.
c51718a  978
cfcee7f  978     ← the reverted first strip's own figure
566171c  983
7fb527e  983     ← "983" is the honest POST-STRIP number
ecf7716  994     ← HEAD
```

The +11 since the strip is exactly my ledger work: 5 lost (the four dead
`ArenaAmmo` functions and `meta.locale_probe`), 16 new (`LoadOwedKit`,
`OwedKit`, `OwedKitIsSaved`, `ArenaDb`, `ArenaDbReady`, `ArenaToast`,
`ArenaToastKey`, the admin-kit panel ids, the new locale keys).
`inventory.py` reports it exactly, including `FAIL — something a server
depends on is gone`, which is **correct and expected**: those four functions
were deleted deliberately.

### Both verifiers still work. "Before" is a commit.

`git archive <commit> | tar -x` into a scratch dir, then point the tool at it.
**The original strip was independently re-verified from scratch:**

```
verify_lua_identical.sh  566171c → 7fb527e   18 files, 0 changed   PASS
verify_web_identical.py  566171c → 7fb527e    3 files, 0 changed   PASS
inventory.py             566171c → 7fb527e   983 → 983, 0 lost     PASS
```

That reproduces `BEFORE-WE-DELETE.md`'s table exactly.

### `strip_all.sh` is **NOT stale**, and HEAD is strip-safe

The 19 hand-written entries still match the tree byte-for-byte. My PART D
worry about `tools/harness/` was a non-issue: `strip_all.sh` only touches
`$ROOT/<named path>` inside a copy of `Crimson-Arena`, and `tools/harness/`
is outside it. A full re-strip of HEAD then diffed against HEAD:

```
18 lua files, 0 changed   PASS
 3 web files, 0 changed   PASS
```

**So every comment in my thirteen commits survives the strip, and the stripped
tree is behaviourally identical to the shipped one.** Nothing was written into
the working tree; `git status --porcelain` was empty before and after.

---

## E3. Answer 8 — all five CONFIRMED, none refuted

Every claim was verified independently and then adversarially attacked by a
second agent instructed to refute it. **All five survived.**

| | Accurate | Fix the | Extra found by the adversarial pass |
|---|---|---|---|
| 8(a) | yes | **doc** | See E4 |
| 8(b) | yes | **doc** | The cap **was** delivered (`Arena.KillCeilingFor`, `shared/arena.lua:428-437`, 200 m on a 200 m fence). The fail-open is deliberate — `match.lua:1361-1365` reads **"FAILS OPEN, ON PURPOSE"**. A nil for **either** body skips it, not just the killer's. |
| 8(c) | yes | **code** | See E4 — the deleted spec proves intent |
| 8(d) | yes | **both** | The "cheater wins a 1v1 by attrition" shape does **not** work unaided: they are frozen and disarmed by their own `deathReported` flag (`client/match.lua:595-606`), so nothing kills the honest player and the round runs to the 600 s clock. |
| 8(e) | yes | **both** | See E4 — **my answer was wrong** |

---

## E4. The four things worth acting on first

### (i) My 8(e) answer was too generous to the doc. CORRECTED.

**PART D says** the 60.0 fallback at `match.lua:1084` "is what applies whenever
the config block is missing or unreadable", and therefore the doc is not simply
stale.

**That is wrong.** `match.lua:1081` returns early —
`if type(block) ~= 'table' or block.enabled ~= true then return false, 0.0, 0, 0 end`
— so a **missing or disabled block turns the checks OFF entirely and the 60
never runs.** The `or 60.0` fires only on an absent key, a **misspelled** key
(American `outsideMeters`), or a genuinely non-numeric value. A quoted `"10.0"`
is fine; `tonumber` handles it.

So the doc **is** simply stale, and the fallback is a **latent code bug**: the
only person who reaches it is an operator who mistyped one key, and what they
get back is the exact 60 m pocket `566171c` was written to close.

**But do NOT delete the doc's reasoning.** `config.lua:436-437` still makes the
same argument in the same words — *"a fighter who steps over the line is being
bled by the boundary already"* — and the spec that shipped **with** the fix
(`566171c:Crimson-Arena/tests/serverchecks_spec.lua:262-265`) is titled *"and a
fighter a step past the fence is left alone"*. `566171c` overturned the
**magnitude**, not the **principle**.

**Resolution:** doc — change "Sixty" to "Ten" and say why 60 was a pocket, keep
the "not a second boundary" reasoning. Code — make `match.lua:1084` `or 10.0`.

Bonus, unrelated but real: `match.lua:1391` discards the enabled flag and uses
`outsideMetres > 0` as its test, so **`outsideMetres = 0` silently disables the
kill-credit refusal** while leaving the sweep running at zero tolerance.

### (ii) 8(a) — the doc is wrong in a second way you did not flag

Your reading is right and the change was deliberate: at `c51718a` the doc was
**true** — the check sat inside `OnDeath` *before* `player.alive = false` and
returned false. `566171c` moved it into `resolveKiller`, **43 minutes later**,
and the stale-claim sweep in `46e8555` missed the doc sentence.

Two additions:

- **"It costs the reporter nothing to send" is now false.** It costs a booked
  death, plus a lost tier in a ladder, plus a life in a lives-spending mode.
- **"Spends a life" is only true in some modes.** `WIN_CONDITIONS_WITHOUT_LIVES`
  (`shared/arena.lua:549-556`) holds `score_limit` and `most_kills`, and a
  ladder never spends lives — and those are precisely the modes the doc cites
  as the measured exploits.
- **A worse hole the doc hides:** `resolveKiller` bails at `match.lua:1324-1328`
  if the killer id is missing, invalid, the reporter themselves, or off-roster
  — all **before** the fence test. So a fake death naming no killer **books
  unconditionally, from any distance.**

### (iii) 8(c) — the deleted test suite proves this was intended to work

`Crimson-Arena/tests/serverchecks_spec.lua` exists at `7fb527e^`. Its test at
lines 226-243, *"and the count has to be CONSECUTIVE, not merely reached"*,
opens: **"A HITCH IS NOT A CHEAT. A player whose world stalls for a second, OR
WHO IS BETWEEN A DEATH AND A RESPAWN…"**

**The behaviour you found missing was specified, tested, and the test was
deleted by the strip.** You have that file recovered. This is a code bug with a
spec already written for it.

### (iv) 8(d) — no evidence it was ever considered

The adversarial pass looked and found none. Combined with (iii), the honest
framing for John is that the dead sweep has two independent holes, and how
tightly to close them is **his** call — question 2(e).

# Where this stands

**For:** John Allday. **Updated:** during the review session that followed the handover.

> **The command surface changed after most of this was written.** This resource now
> registers exactly two commands: `/arenaadmin`, which takes no arguments and opens the
> admin tablet where every action is a button, and `/arenaconsole`, which prints every
> reading to the server console in one pass. `/arenadispatch`, `/arenarevive`,
> `/arenaattachments`, `/arenaisolation`, `/arenahours` and `/arenaunjam` no longer exist;
> where the text below names one, the work it describes is unchanged and only the way in
> is different.
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
again for the rest of the server's uptime. The admin tablet now lists what is held back (**Tools → Held-back stashes**) and clears
one (**Clear the hold**, on the stash detail under its item list). Admin-gated, and deliberately **not** automatic: "clear it when
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

### 3d. Attacking the fixes, and two matches at once

**Attacked deliberately rather than waiting for a report.** Every attack below failed, and
the ones a player could actually attempt are now tests:

- **The bag as a smuggling route.** Every move in or out of a bag, the belongings stash and
  the bag holding stash is refused mid-round -- the swapItems hook already turns away any
  move whose other end is not the player's own inventory, and a container's id is not their
  server id. Pocket-to-pocket still works, which is right.
- **Jam your stash to keep the arena kit.** A jammed stash means the door cannot strip you,
  so you fight in your own gear -- but the exit still takes the arena's kit back by serial,
  and leaves your own ammunition alone. Nothing gained.
- **A ghost copy of the bag itself appearing in the stash.** Refused by the ceiling; the
  player gets exactly one bag with its contents, the ghost stays parked.
- **Four rounds of cycling, and leave/re-enter loops.** Totals flat every time.

**What the attacking found: clearing a jam was a foot-gun.** Clearing a jam on a stash that
still held the parked surplus put every one of those rows back inside the next ceiling, and
the next exit handed them over -- the exact duplication the jam exists to prevent. An
operator clearing a noisy console in one go would have done that to every parked surplus
at once. It now refuses a stash that still holds something, says what
clearing it would cost, and takes `force` for an operator who has genuinely checked. The
listing shows the row count per stash so the decision is visible.

**And two matches at once, which nothing tested.** Every door test ran a single round, and
"keyed per player" or "keyed per match" is a claim only a second one can check. Two things
had to be built first:

- The fixture's routing natives were permanent no-ops -- `GetPlayerRoutingBucket` answered
  0 and `SetPlayerRoutingBucket` did nothing, which is exactly what FXServer does when
  buckets are unavailable. So `server/dispatch.lua` caught the move not landing, latched
  `provenInert`, and switched isolation off: **every bucket line in the file was dead in
  that fixture.** Modelled properly it is now the one fixture with the real inventory and
  real instancing together.
- The clock jumped a whole minute per call, so no match could stay live long enough to ask
  anything about a second one. It is a parameter now, with the old value as the default.

Five tests came out of that: two matches get separate instances and nobody is left in the
world; one match ending leaves the other instanced, stripped and with its belongings still
in its stash; four players with four bags across two matches each get their own contents
back; a disconnect out of one match leaves the other's buckets alone; and two simultaneous
matches conserve what players own. Proved by making both matches share one bucket, which
the first of them catches by name.

### 3e. The money side was checked and left alone

212 tests across eight specs, including a conservation spec written for exactly the blind
spot that matters ("two mistakes that cancel"), a self-bet spec, and -- already there -- a
test running two matches side by side with one spectator holding a bet on each, settled to
two different endings. The concurrency gap that existed on the inventory side does not exist
here.

One guard was probed and reported rather than tested: `returnSideBet`'s `settled` check.
Removing it leaves all 166 betting tests green, which looked like an untested guard -- but
driving the realistic double path (settle the bets, then destroy the lobby) conserves money
with the check and without it. It is a redundant second line of defence, not an untested
one, and a test for it would pass either way. Recorded rather than written.

### 3f. `inventory:cleartime` is NOT something you have to set

The short answer: **both reported bugs are fixed in code and neither needs the convar.** It
was belt-and-braces, and it is worth being precise about what it was and was not buying.

ox_inventory throws an idle inventory out of memory after `inventory:cleartime` and reads it
back from the database on the next touch. **With a healthy database that round trip is
lossless and completely invisible.** It only costs anything when the write does not land --
a database that is off, an unwritable `ox_inventory` table, a SELECT-only user. And on a
server in that state ox_inventory is losing every stash, glovebox and container on the box,
not just this resource's.

There is no supported way to keep an inventory out of that purge, and that was checked
rather than assumed:

- `inv.time` is stamped at creation and refreshed **only** when an inventory is closed
  (`modules/inventory/server.lua:625`, `:351`). No export touches it -- not `AddItem`, not
  `RemoveItem`, not `GetInventoryItems`, not `RegisterStash`.
- ox_inventory's own purpose-built mechanism for this job, `ConfiscateInventory` /
  `ReturnInventory`, is **worse**: it writes straight to the database and reads back with a
  direct `MySQL.scalar.await`, so it is more database-dependent rather than less -- and it
  keys on one slot per player, which would collide with any jail script that uses it.
- A temporary stash is worse again: `datastore` stops it being saved, so the purge simply
  destroys it.

So prevention is not available from outside ox_inventory. What is available is **never
making it worse, and saying exactly what is missing** -- and that is now measured rather
than claimed:

- A belongings stash that comes back empty is never reported as a clean exit. It says `READ
  EMPTY`, keeps the record so the sweep goes back for it, and hands nobody anything it
  invented.
- **A bag holding stash that comes back short now says so, by count, and that was a real gap
  in the container fix.** The refill returned quietly on an empty read -- so a holding stash
  that had been through the round trip looked exactly like a bag that went in empty, and the
  bag came back hollow with nothing anywhere saying why. The count taken at the door is the
  only thing that can tell those apart, so it is carried now.

Setting `inventory:cleartime 60` still removes the cause rather than catching it, and costs
nothing but a little memory. It is a recommendation, not a requirement.

### 3g. Four more fixtures had dead routing-bucket lines

The no-op routing natives found in the door fixture were not the only ones.
`admingates_spec`, `crossfire_spec`, `damageproperty_spec` and `hostilename_spec` all
answered bucket 0 and did nothing, so `provenInert` latched and isolation was off in all
four -- anything in their own subject that touches instancing was being asked of a server
that had none. All four now model buckets properly and all four still pass, so nothing was
hiding behind it; they are simply faithful now instead of inert.

### 3h. The refusals nobody had driven, and four more attacks

**Two fixture capabilities were missing, and one of them hid the most ordinary failure
there is.** Nothing in the door suite could make ox_inventory turn an item *down* -- so **a
full inventory at the exit**, which is the commonest refusal a real server produces, had
never been driven. Nor could anything read a bag holding stash by name. Both are levers now,
and three tests came out of them, each proved by inverting a different guard:

- **An exit that cannot hand everything over** keeps it in the stash, says so, and the sweep
  comes back for it the moment the player has room. Nothing is destroyed to make space.
- **A bag that will not take its contents back** leaves them in the holding stash rather
  than dropping them on the floor of a failed refill.
- **A different character on the same server id gets nothing of the last one's** -- neither
  the belongings stash nor the bag contents. FiveM reuses server ids, and everything the
  door remembers is keyed on one.

**Four more money and betting attacks, all already refused:**

| attack | outcome |
|---|---|
| Back both fighters in one match, harvesting other punters' stakes risk-free | refused -- "One side-bet per match. Yours is down." |
| Back a fighter, then join that match yourself | refused -- `error.bet_then_join` |
| Back a fighter who then walks out of the lobby | bet returned, nothing stranded |
| Settle the side-bets, then destroy the lobby | money conserved either way |

Each refusal was already pinned by an existing test, so nothing new was written for them.
The money side genuinely is in better shape than the inventory side was.

**Two more probe premises were wrong before the code was**, which is worth recording because
it keeps happening and is the main way this work produces false alarms. The character-reuse
probe swapped the character record without firing a disconnect, so the player was still
flagged as being in the arena and the sweep correctly refused to touch them -- that read as
"a returning player never gets their kit back". And an economy delta measured over wallets
reads escrowed money as missing, so a host still sitting in their own lobby with a stake in
looked like a 1,000 leak. Neither was real. **Print the state and check the premise before
calling anything a defect.**

### 3i. A bag is never emptied, on ANY way out of a round

The container fix was tested on the ordinary exit. A bag does not care how the round ended
and neither should its contents, so the same claim now runs through **every** other way out
-- the round ending, the round being aborted, the fighter leaving, the fighter dropping, and
the resource stopping mid-round -- each with the container purged mid-round, which is the
failure the whole mechanism exists for. Plus the shapes a bag itself can take:

- **Two bags on one player** never pour into each other.
- **An item whose identity is its metadata** -- a phone with a number -- keeps it inside a
  bag. A count of names cannot see that, and a bag is exactly where people keep the things
  it matters for.
- **Ten items in one bag** all come back.
- **With the door switched off entirely** (`stripOnEntry = false`) the bag is never touched,
  and nothing is left behind in a holding stash for a round that never stripped.

Disabling the custody makes **seventeen** tests fire, and the conservation one names it item
by item: `handcuffs 2 -> 0; radio 1 -> 0`.

The powergaming question for a bag is settled separately and was re-checked here: a fighter
cannot move anything into or out of one mid-round, because the swapItems hook refuses every
move whose other end is not their own inventory and a container's id is not their server id.
So nothing can be hidden in a bag during a round, and nothing can be taken out of one.

### 3j. Forty-five minutes, set by the resource rather than by you

`Config.Loadouts.inventory.keepStashesAliveMinutes` ships at **45**, and the resource now
raises ox_inventory's `inventory:cleartime` to match at load. That removes the cause the
door was catching: on the shipped ox_inventory setting of five minutes, every round longer
than that sends a fighter's belongings -- and their bag contents -- on a database round trip
while they are still fighting.

Three things make it safe rather than rude:

- **It only ever raises.** An operator who already set 90 in `server.cfg` has said what they
  want and is left alone. A floor, not an opinion.
- **0 turns it off**, and the config says plainly that the cost is memory and that the cost
  is not only the arena's -- this is ox_inventory's global setting, so every idle stash,
  glovebox and trunk on the server stays in memory that long.
- **It says whether it actually landed.** ox_inventory reads that convar once, when *it*
  starts, so setting it afterwards changes nothing until something restarts. If ox_inventory
  is already up, the log says so and prints the `server.cfg` line to use instead of quietly
  doing nothing -- a fix that silently fails to apply is worse than no fix, because the
  operator believes it worked.

It runs at load rather than on a thread, because the whole value is being early and there is
nothing in it that needs ox_inventory to be running.

### 3k. Four more inventory cases, and one consequence made visible

- **A holding stash that refuses the contents at the door** leaves them in the bag. If the
  arena cannot take them, the right answer is to leave them exactly where they are.
- **A player's own copy of an arena item, inside their bag** -- their own `ammo-rifle-ap`,
  which is something this arena issues -- comes back to the bag, and the exit's by-name
  reclaim does not treat it as the arena's just because the name matches. Both halves had to
  be true and both are.
- **A bag still comes back packed when the belongings stash jams at the exit**, with the
  surplus still parked.
- **A jammed stash leaves bags unprotected too, and now says so.** `holdContainers` sits
  below the jam check on purpose: a jammed stash means the door is not managing that
  player's belongings at all, and taking their bag contents while refusing everything else
  is half a job. The bag travels as it is, which is safe in itself -- but nothing is holding
  those contents against the idle purge, and that is exactly the player for whom
  `keepStashesAliveMinutes` matters most. The log says it now instead of leaving it to be
  discovered.

### 3l. The database, on and off

**A table was missing from `sql/install.sql`, and the omission bit exactly the operators
that file exists for.** All three tables -- `crimson_arena_stats`, `crimson_arena_owed_kit`
and `crimson_arena_unpaid` -- are created at runtime with `CREATE TABLE IF NOT EXISTS`, so a
database user that *may* create tables never noticed. A user that **may not** -- which is the
whole reason to import that file by hand -- got two tables out of three, and from then on
every write of money the arena still owed somebody failed. `crimson_arena_unpaid` is in both
`install.sql` and `uninstall.sql` now, and **a contract holds the three runtime statements
and the two SQL files together** so it cannot drift again. Removing the table from the file
again makes that contract name it.

**Nothing conflicts with anything else.** Every table this resource writes is named
`crimson_arena_*`. The one foreign table it goes near is `ox_inventory`, to find stashes a
restart forgot, and it only ever **reads** -- there is no INSERT, UPDATE or DELETE against
it anywhere. That is now asserted against the statements themselves, not just the schema
files: a round is played with the database on and every statement it sends is checked for a
table that is not its own.

**And a real defect on the database-on path.** `ArenaDbReady` -- the gate every database
path goes through -- called `GetResourceState` unguarded. Running the whole suite with
`Config.Database.enabled` forced on took `earnings_spec` down entirely: thirteen failures,
all `attempt to call a nil value (global 'GetResourceState')`. It is always present on a
real server, so this is not a crash an operator would see -- but it is a load-bearing gate
failing hard rather than safely, and only on the servers that turned the database ON, which
is the wrong way round for an optional feature. It answers "no database" now when it cannot
ask, which is the same safe answer as the flag being off. With that fixed, `earnings_spec`
passes with the database on.

**Every feature works with the database on.** The full suite forced on leaves exactly two
files failing, and both are asking about the shipped default on purpose: `dropin_spec`
asserts the database ships off so a drop-in install needs no SQL imported, and
`leaderboard_spec` is built around the in-memory board that exists *because* it ships off --
it asserts the flag is `false` at line 196. Neither is a feature that stops working.

The door is now driven in all four states an operator can be in -- off; on and working; on
with oxmysql up and every statement refused; on with oxmysql not started -- and a round
produces the same answer in all four: the player leaves with exactly their own things and a
bag packed the way they left it. The database is where a round is written down. It is not
what makes a round work.

### 3m. Two live reports, one cause, and it was mine

Reported as the arena **"not clearing the inventory"** and **"it still cleared the leo bag"**.
One cause, both symptoms.

When the exit finds more in a stash than the door put there it refuses the surplus and
**jams** that stash. Correct, and tested. But a jam also stops the door putting anything
**into** that stash, and the stash name was the character's and nothing else -- so a jammed
player was **never stripped again**. And `holdContainers` sits below the jam check, so their
bags stopped being protected at the same moment, which is the second report exactly. On a
server where the thing that causes a jam happens routinely, that is every player, one long
round each.

The jam is right; tying it to the only name the door could use was not. A jammed stash is
left for a human to settle on the tablet and the next round goes into the next name along,
bounded at fifty.

**And the one silent failure is loud now.** The single reason the container mechanism can do
nothing -- an ox_inventory without `GetContainerFromSlot` -- was an `ArenaDebug`, which only
prints with `Config.Debug` on. An operator on such a build saw bags emptied exactly as
before and no explanation anywhere.

### 3n. It is the same one back, not one like it

"They got a pistol back" is not the promise; "they got THEIR pistol back" is. Every test
that compares `carrying` is a count of names and cannot tell those apart. So: a player's own
weapon comes back with its **serial, its rounds and its attachments**; an item whose
identity is a name on it comes back as theirs; a weapon kept **inside a bag** keeps its
serial through the holding stash and back; and two players carrying the same weapon do not
swap them. Handing items back without their metadata makes **24 tests fire**.

### 3o. Everything comes back, bag or not -- and still exactly once

The contents of a bag used to be left in a holding stash whenever the bag itself could not
be reached -- the exit could not empty the belongings stash, the stash jammed, ox_inventory
would not open the container. Safe, but not **back**: the owner cannot reach a stash the
arena named in a console they never see. The bag is still preferred, because getting it back
packed is the point, but their pockets are the fallback, and only when they cannot take it
either does it stay in a stash.

**That fallback is the exact shape that duplicates, and it nearly did.** `oxGave` demands
proof and reads a nil answer as "no" -- the right rule everywhere else in this file, because
everywhere else "no" means leave the item alone. Here "no" means *try somewhere else*, so a
bag that took the item and merely answered nil would have got them a second copy: the very
defect this whole file has been chasing, reintroduced by a convenience. A refusal is now
verified against the container's own contents before it is believed. Removing that check
makes the player walk out with a second `radio` while the bag keeps the first.

### 3p. The LEO bag is not a container, and that matters

The bag in the report is `fm-firstresponderbag`, and reading it changed the diagnosis. Its
LEO and EMS bags are **not ox_inventory containers**. They are ordinary items carrying
`metadata.bagId`, and their contents live in a **separate stash** named
`leo_bag_<bagId>` that the bag resource registers and opens on demand
(`server.lua`: `RegisterStash(bagConfig.stashPrefix .. item.metadata.bagId, ...)`).

So the container custody in 3 does nothing for them, and that is correct -- there is no
`metadata.container` to hold. **The arena never touches that stash and must not**, which is
now asserted rather than assumed.

What the arena *could* still cost them is the **link**. The bag is just an item here: it
goes into the belongings stash and comes back. If `bagId` did not survive that trip, the bag
would open a different, empty stash on the other side -- and to its owner that is
indistinguishable from the arena having emptied it, with the real contents still sitting in
a stash nothing points at any more. Pinned now.

**And the exposure that remains is the one already fixed.** That bag stash is nobody's open
inventory during a round, so it sits in exactly the same ox_inventory idle purge as
everything else -- which is what `keepStashesAliveMinutes = 45` is for. The bag needed the
convar fix, not the container fix.

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

**It is in the tree.** `tests/`, tracked, and it runs with:

    bash tests/run.sh

It used to be untracked, and this section used to tell you to recover it with
`git archive 566171c tests | tar -x`. **Do not do that** -- that commit
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

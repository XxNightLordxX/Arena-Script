# Deploying Crimson Arena

Read this before the resource goes anywhere near players.

## The honest status of this build

Everything that can be checked without a running FiveM server has been checked:
every Lua file parses, `luacheck` is clean across the resource, and the spec
suite exercises the real production files under plain Lua 5.4 — the rules, the
payout arithmetic, the escrow invariants, the locale coverage.

The client is also run against a *model* of the game — `tests/fixtures/world.lua`
gives it objects, prop dimensions and a streaming bubble, and the real
`client/match.lua` builds the sky arena inside it. That model found three
defects the reading had missed. It is still a model.

**None of it has ever loaded into FXServer.** No ped has spawned, no panel has
opened, no weapon has been handed out, no routing bucket has replicated. Tests
prove the *rules* are right, and the model proves the *sequence* is right. Only
the game proves the natives behave.

So: the smoke test below is not a formality. It is the part of the verification
that this build has not had, and it takes about half an hour — closer to an
hour if you have switched ammo types on, which adds a section of its own.

**The arena in the sky is the one to check first.** It is the only part of
this resource that builds its own ground, it has the least real-world evidence
behind it, and it fails in the most expensive way. It has a section of its own
below and it is deliberately near the top.

## Install

1. Drop this `Crimson-Arena` folder into your resources directory. It is
   already named the way it should be named there. The name is still yours to
   change if you want -- the panel asks the game which resource is serving it
   rather than assuming, and the exports are registered under whatever you
   chose.
2. `ensure <that folder name>` in your `server.cfg`, anywhere after
   `qbx_core`. Those are the only two hard dependencies — `qbx_core` and
   `ox_lib` — and they are the whole `dependencies` block. `ox_target`,
   `ox_inventory` and `oxmysql` are checked at run time by the features that
   need them, so a server missing one still starts: no lobby NPC is spawned,
   nobody is issued ammo items, and the leaderboard covers the server run.
   Each says so once in the console.
3. Optionally import `sql/install.sql`. **`Config.Database.enabled` ships
   `false`**, so on a default install there is no table and no query at all —
   the leaderboard keeps its numbers in memory for the server run. If you turn
   the database on, the resource creates its one table itself on first start;
   import the SQL only if your database user cannot `CREATE TABLE` at runtime,
   which is a reasonable way to run a production server.
4. Start the server and read the console. The resource prints its own config
   validation and, a few seconds later, the dispatch detection report.

## Configure before the first match

Open `config.lua`. The three things that are certainly wrong for your server:

- `Config.Lobby.ped.coords` and `Config.Lobby.returnCoords` — the shipped
  coordinates are placeholders. Stand where you want the NPC and use your
  server's coordinate command.
- `Config.Arenas` — **two ship enabled, and they are very different animals.**

  `trailerpark` is a real place on the map. It has its own trailers, fences and
  vehicles to fight around, so it spawns nothing of its own — its `cover` block
  is laid out but switched off, because fixed offsets know nothing about what is
  already standing there and turning it on drops a shipping container through
  somebody's caravan. Coordinates are the operator's own; change them the same
  way you changed the lobby.

  `skydome` is built, not found: a floor of props tiled into a disc at 1201 m
  over open water, with cover on top, spawned per match and deleted when it
  ends. Nothing under it. It also **grows with the roster** — six fighters get
  the 35 m circle in config, twenty get a 57 m one on a floor to match.

  The config carries a copy-paste block for adding more.
- `Config.Betting` — decide whether money is in play at all before players can
  stake it. `Config.Betting.enabled = false` if you are unsure.

One thing ships **off** and stays off unless you decide otherwise. It is not a
placeholder you have to fix; it is a switch you have to mean:

- `Config.Database.enabled` — off, so the leaderboard lives in memory for the
  length of the server run and resets on restart. Nothing else reads the
  database. Turn it on for an all-time board.

And one that used to ship off no longer does:

- `Config.Loadouts.ammoItems.enabled` — **on**, and the item names are real:
  every weapon in the list names the round it actually fires (`ammo-9`,
  `ammo-shotgun`, `ammo-heavysniper`), read out of that weapon's own
  `ammoname` in ox_inventory. If your server names its ammo items differently,
  edit the `item` field on the weapon's own `ammoTypes` line — handing out a
  name that does not exist is a silent nothing that players report as the
  arena being broken. Either way, test it with the **Ammo types** section
  below, because it is the only part of this resource that touches a player's
  inventory.

## Adding or moving cover

The `cover` block of an arena is a plain list and it is meant to be edited. Two
things about it are not visible from the list itself, and both of them bite.

**Cover costs spawn room, and the bill lands on the SMALL rosters.** Spawn
placement excludes a disc around every piece of cover, and unlike the separation
between fighters that exclusion is never relaxed — a crowded arena is a worse
round, but a spawn inside a wall is a player who cannot move. So cover does not
make placement harder as you add it, it makes it impossible past a point. The
counter-intuitive half is which rosters break first: a large roster grows the
arena, and growth moves the cover outwards while the piece count stays the same,
so twenty fighters have proportionally more room than four. A ring of containers
that holds twenty comfortably can leave four standing on top of each other.

**Two pieces in one place is what makes an arena look broken.** A shipping
container is twelve metres long, so two rings a few metres apart intersect even
though their centres look well separated in config. Overlapping surfaces flicker
against each other because the renderer has no way to decide which is in front,
and it stays solid underfoot the whole time — so it reads as the arena being
broken rather than as a prop in the wrong place.

Both are checked, so you do not have to hold them in your head. `tests/run.sh`
fails if two pieces are within the distance a rotated prop sweeps, if any two
intersect at the headings you wrote, if the shipped arena stops placing every
roster from two to thirty-two at its stated separation, or if it stops placing
eight fighters **with growth switched off** — which is the one that actually
bites, because a roster big enough to grow the arena gets the extra room for
free and hides the problem.

Edit the list, run the suite, and read what it says. Do not trust a layout that
merely looks right: the numbers in the skydome's `cover` block were arrived at
by measuring against all four of those, and a denser version of them passed
three before failing the fourth.

## The smoke test

Run this on a development server, with at least two accounts. Each step names
what to watch for, because most failures here are silent.

### 1. It starts

Two of these are in the **server console**, two are in **F8** on a client. They
are separate places and the client ones cannot appear in the server log.

- [ ] Console shows no Lua error on `ensure crimson_arena`.
- [ ] The config validator printed nothing, or printed only things you expect.
- [ ] The dispatch report lists your real dispatch and ambulance scripts. If it
      says nothing was detected and you know you run one, the resource does not
      recognise its name — add it, or use the hooks.
- [ ] **F8 shows the lobby line**, naming the fixture, its coordinates and the
      interaction mode:

      ```
      [crimson_arena] lobby: NPC at -282.01, -2030.46, 30.15 (interaction = ped).
      ```

      This one line separates three failures that otherwise look identical:
      the config edit was ignored, you are standing at the old spot, or the
      folder the server runs is not the folder you edited. A line reading
      `lobby: NOTHING -- see the warning above` is a fourth and different
      thing: the NPC could not be spawned, and the reason is printed just
      above it. **No line at all means the startup thread died** — read
      upward for the error.

- [ ] **F8 shows no `PROPS MISSING` line.** Every prop the arena spawns names a
      chain of models and the client checks them against your build a couple of
      seconds after start. Silence is the pass. If a chain has run out you get:

      ```
      [crimson_arena] PROPS MISSING ON THIS BUILD -- an arena below cannot be built and will refuse to start:
          skydome floor -- none of: stt_prop_stunt_bblock_huge_01, ...
      ```

      That arena will refuse to start rather than drop anyone into open air.
      Every chain ends in a base-game model, so this should not happen on a
      stock install — see `stream/README.md` if it does.

      With `Config.Debug = true` you get the full report either way, naming
      *which* model out of each chain your build supplied. Worth reading once.

### 2. The arena in the sky — do this before anything else

The only part of this resource that builds its own ground. Everything here is
natives, it has the least real-world evidence behind it, and the failure mode
is a kilometre of air.

- [ ] Fly to `1500, 3000, 1201`, outside a match, and look. **You should see
      nothing** — the floor exists only while a match is running, and only for
      the clients in it.
- [ ] Now start a match in **The Skydome** with two players.
- [ ] **There is a floor, and you are standing on it.** Not falling, not inside
      it, not hovering above it.
- [ ] **The barriers are on top of the floor**, not sunk into it and not
      floating. They used to be buried by exactly the height of the floor prop.
- [ ] Walk the whole disc, including the diagonals and the outer edge. **No
      holes.** A gap here is a fall of a kilometre, and the diagonals are where
      the old tiling left them.
- [ ] **There is a wall all the way round, two containers high, and you cannot
      get past it or over it.** Walk the whole ring and push into every joint.
      Twenty-two segments close a 44.5 m circle out of 12.19 m containers, so
      adjacent pieces come within 0.19 m of touching — a shoulder should not
      fit through, and 5.2 m of steel is not something a ped vaults.
- [ ] **Nothing is over your head.** The wall surrounds the arena; it does not
      roof it. If you are looking at a container ceiling, something is stacked
      that should not be.
- [ ] **The containers stand side-on to the middle, not end-on.** A ring of
      spokes is what a wall looks like when the client could not measure the
      prop — every piece turned ninety degrees, with a twelve-metre gap
      between each one. If you see that, the model chain fell back to
      something this build has no dimensions for, and the console says which.
- [ ] **Walk to the very edge of the floor and stand there. Nothing should
      happen.** This is the one to be deliberate about, because it used to be
      wrong: the boundary was 60 m around a floor that reached 77, so the outer
      seventeen metres of solid platform were outside the arena and standing on
      them bled you. The boundary is 110 m now — with the shipped prop the
      floor reaches about 85 m with the 40 m stunt block, so there is real slack —
      and the client measures the floor it actually built and prints `THE
      FLOOR REACHES OUTSIDE THE ARENA` if it ever exceeds the boundary.
      **That is a warning, not a refusal.** `Arena.ValidateConfig` collects
      problems and `ReportConfigProblems` prints them followed by, in as many
      words, "the resource is still running -- these are warnings, not
      failures". Nothing here refuses to start over config. **A bleed warning while you
      are still on solid ground is a bug, and it is one this build is supposed
      to have made impossible.**
- [ ] **Expect the floor to reach a little past `platform.radius` at the
      corners.** The floor is tiled, and a tile is kept whenever any part of it
      is inside the radius — coverage beats tidiness, because trimming to the
      radius leaves a hole and a hole here is a fall of a kilometre. So the
      outer ring sticks out by up to half a tile, and on the diagonals by half
      a diagonal. That is deliberate. It is inside the boundary either way.
- [ ] Try to walk off the edge. **You should not be able to** -- the rim is
      fenced by the wall you checked above, and getting past it is the
      failure. If you do get past it, the boundary is what catches you: you
      leave the sphere from underneath within a second and the bleed finishes
      you if the kilometre does not. Either is a pass for the boundary --
      neither should ever happen with the wall standing.
- [ ] Die once. You come back **on the floor**, not on the terrain a kilometre
      below and not under the platform. **Expect a short drop on landing** —
      you are placed `Config.Match.spawnHeightOffset` above the surface (3 m as
      shipped) and released. Turn it down to `1.0` once you are satisfied the
      floor is solid; it exists because a ped placed level with a prop has its
      origin inside it and falls through, which is exactly what was reported.
- [ ] End the match. **Fly back to `1500, 3000, 1201`. Nothing is left
      standing.** A prop nobody deletes stays there for the rest of the session,
      in an instance you cannot normally reach to look at it.
- [ ] With `Config.Debug` on, F8 names the piece count and the surface height:

      ```
      [crimson_arena] arena scenery: 87 of 87 piece(s) built -- 9 floor, 78 cover, furthest cover 44.53m out.
      [crimson_arena] arena scenery: the floor prop measures 40.00 x 40.00m and its surface is at 1201.00.
      ```

      **The cover count is always 78** -- 44 in the perimeter wall (22
      positions, each doubled), 12 in the outer ring, 8 in the mid band, 8 in
      the four corner pockets and 6 in the middle. Every cover chain ends in a
      base-game model, so it does not depend on what your build supplied, and
      **`furthest cover 44.53m out` is the wall** -- a much smaller number
      means an older `config.lua`.
      **The floor count does depend on your build**: 9 tiles with the 40m
      stunt block the chain leads with, 137 with an 8m prop, 297 with the
      base-game shipping container at the end of it. A much larger count is
      not a fault, it means your build fell back down the chain. Both grow
      with the roster, which is why the line prints the measurement.

      **`0 floor` is the failure to care about.** If the piece count is
      zero entirely, the floor was asked for somewhere the engine was not
      holding the map — which is the bug this arena shipped with.

- [ ] If you can muster the players: run one with a **large roster**. The arena
      grows with it, so the floor and the spawn ring should visibly be bigger,
      and nobody should start the round standing on anybody.

### 3. The trailer park — the other arena that ships enabled

The opposite case, and worth five minutes precisely because nothing is built:
it is real map ground with real trailers on it, and everything that could go
wrong here is something the resource did that it should not have.

- [ ] Start a match in **Trailer Park** with two players.
- [ ] **Nothing new has appeared.** No containers, no barriers, nothing dropped
      through a caravan. This arena's `cover` block ships switched off for that
      reason; it is left laid out in `config.lua` in case you ever want it.
- [ ] **You are standing on the ground**, at the height the ground actually is,
      not three metres above it. The lift in the sky arena is for a floor that
      has to be built; on real ground the game is asked where the ground is and
      you are put on the answer.
- [ ] Walk out to the far rows of vans, the track in, and the fence line.
      **No bleed warning inside the park.** The boundary is 100 m and grows to
      135 at a full roster; sixty metres used to reach the spawn ring and very
      little else, so chasing somebody round the place you came here to fight
      in started the bleed.
- [ ] Keep walking, out towards the highway. **The warning does arrive**, and
      then the bleed. A boundary that never bites is not a boundary.

### 4. The lobby
- [ ] The NPC is standing where you put it, not floating or sunk.
- [ ] Your target script offers the arena option on it.
- [ ] The panel opens, and your mouse works in it.
- [ ] **Press ESC. The panel closes and your mouse returns to the game.** A
      stuck cursor here is the single most disruptive failure this resource can
      have; check it before anything else.

### 5. A match, two players
- [ ] Create a match, second player joins, both see each other in the roster.
- [ ] Pick a weapon and an ammo amount. Pick a team if the mode has them.
- [ ] Start it. Both players are teleported, frozen, then released together.
- [ ] **You have exactly the weapon and ammo you chose — no more.** Your own
      kit went into the arena stash at the door and comes back at the end.
- [ ] Kill each other. The HUD scoreboard updates.
- [ ] The match ends, both are returned to `returnCoords`, and **your own
      weapons and armour are back**. Losing a player's inventory is the
      unforgivable failure; verify it deliberately rather than assuming.

### 6. Dispatch — the reason most of this exists
- [ ] Fire a weapon inside the arena. **Your police script gets no call.**
- [ ] Die inside the arena. **Your ambulance script gets no call, and no medic
      is paged.**

      If it IS still paged, read the console rather than guessing -- the first
      death in any match prints which resource answered before the arena did,
      and there are only three things it can be:

      1. **Start order.** `ensure Crimson-Arena` must sit ABOVE your medical
         and dispatch scripts in `server.cfg`. The arena stops the call by
         answering the death first; answer second and the alert is sent from
         the player's own client before anything here runs. The console names
         the resources that beat it and quotes the line to move.
      2. **The down flag.** Those scripts keep "this player is down" as
         framework metadata, and the arena clears it at the death itself and
         holds it down — `Config.Dispatch.downState.keys`. If yours uses a
         different key, add it there. With the flag down, sc-dispatch's poll
         never raises a call and sc-ambulance's own guard refuses one.
      3. **A name that does not match.** Everything in
         `Config.Dispatch.custom` is a list of real event and export names.
         If your build renamed one, the arena is listening for something that
         never fires -- and says so, once, naming what it saw instead.
- [ ] Have a third player stand outside the arena. They cannot see or hear the
      fight (routing-bucket isolation).
- [ ] **Run `/arenaisolation` while a round is live.** It prints what the server
      is really doing rather than what the config asked for: the mode reported
      for `onesync`, the bucket each live match was allocated, and the bucket
      the server says each of those players is standing in right now. Every row
      should end in the number the row before it asked for. A row ending
      `NOT INSTANCED`, or two players sharing a number across two different
      match ids, means isolation is not happening -- fix that before opening
      the arena, because it is what lets two matches share one platform.
- [ ] Leave the arena and fire a weapon in town. **Your police script DOES get
      a call.** This is the test people skip, and it is the one that catches a
      suppression flag that leaked — a player who stays permanently invisible to
      dispatch is far worse than one who never was.

### 7. Money, if betting is on

**Watch both pockets, not the one you bet from.** Every failure this section
exists to catch is invisible from a single balance: money that left the bank
and came back as cash looks like nothing happened if you only look at cash.

- [ ] Join with a stake. It leaves your account immediately, and **the one you
      picked** — pick `bank` at least once and confirm your cash did not move.
- [ ] Win. The pot arrives, in **the account you paid from**, and the
      arithmetic is what you expected.
- [ ] **Back yourself, with nobody else betting, and win.** You should be told
      the pool was uncontested and handed your stake back — not told you won
      and paid nothing. Do it from the **bank** too: bank out, bank back.
      This is the one that was reported as "self betting just takes your
      money", and it was true twice over.
- [ ] **Back yourself, with nobody else betting, and lose.** Same answer:
      handed back. A pool with nobody on the other side has no money in it but
      your own.
- [ ] Now do it properly: **one player backs themselves, another backs their
      opponent.** That is a real bet and it settles — the winner takes both
      stakes, the loser's is gone.
- [ ] If you run **`fighterBets.enabled = false`**, run one match with an entry
      fee and confirm **the winner takes the pot**. These two settings used to
      cancel each other out: every entry fee was treated as a bet a fighter had
      placed, so all of them were voided and handed back and nobody ever won.
- [ ] Start another, then have a player **disconnect mid-round**. Check the
      remaining players are paid and nothing is stranded.
- [ ] Start another and **restart the resource mid-round** (`restart
      crimson_arena`). Every stake must come back. Every player must be back in
      the world, visible, with their own gear.

### 8. Ammo types, if you switched them on

`Config.Loadouts.ammoItems.enabled` ships `true`, so do not skip this: it is
the only code in the resource that puts an item into a player's inventory,
which makes it the only code that can duplicate one. An arena that hands out
ammunition and does not take it back is an ammo printer. (If you have switched
it off, skip the section — nothing below can happen.)

Run it with `Config.Debug = true` so the grant and the reclaim both print, and
keep the inventory UI open next to you.

**The right item arrives**

- [ ] Pick a weapon and note which item its `ammoTypes` line names — the
      Pistol maps to `ammo-9`, the Heavy Sniper to `ammo-heavysniper`. You are
      not asked to choose a round: the panel offers no picker for a weapon
      with one type, and the round comes from the weapon.
- [ ] Start the match. **That exact item is in your inventory**, and **the
      total is what you picked.** 60 rounds on the Pistol is 30 in the
      magazine and 30 items in the pocket — not 60 and 60, which is what it
      used to be, on every weapon of every round.
- [ ] **Count it.** Open the weapon and read the magazine, then count the
      items. They must add up to the number you chose. This is the one check
      in this section that a passing console line cannot make for you: both
      halves logged success while the player carried double.
- [ ] Pick the **smallest** amount the weapon offers — 30 on the Pistol — and
      start again. **All of it is in the gun and there are no loose rounds**,
      which is correct: thirty rounds is thirty rounds.
- [ ] The console shows `weapons: gave <weapon> x1 to <src> (ammo <n>)`, and
      `<n>` is the MAGAZINE, not the whole pick. **There is no line for a
      successful ammo-item grant** — the round-counting ledger that printed
      one is gone, and `ArenaAmmo.Issue` logs only failures now. Silence here
      is success.
- [ ] **No `could not give` line.** One of those names an item that does not
      exist on your server, or an inventory that was full — it is the only
      place a wrong item name ever shows up, since nothing validates the names
      at startup.
- [ ] Pick a **different weapon** and start again. A different item arrives —
      a shotgun should bring `ammo-shotgun`, not the pistol's `ammo-9`. If two
      weapons bring the same item, two `ammoTypes` lines are pointing at the
      same name.
- [ ] Pick a weapon whose magazine is **not** 30 — the Heavy Sniper loads 10,
      the launchers load 4. Forty rounds on the Heavy Sniper is 10 loaded and
      30 spare. If everything loads 30 regardless of the weapon, the split is
      falling back to `defaultMagazine` instead of reading the weapon.
- [ ] Take a **melee weapon** and start. No ammo item is issued and no type was
      ever offered — melee is excluded automatically.
- [ ] Take an **MK II weapon** and start. Twelve ship and all twelve are
      enabled, and — like every other weapon in the list — each names its own
      `item` and **no component**. Nothing in the shipped config attaches an
      MK II magazine: `COMPONENT_` does not appear in `config.weapons.lua`
      at all.
      Since every weapon carries its own list, editing `defaultAmmoTypes`
      alone changes nothing for any of them.

**It is gone after the match**

- [ ] Finish the round normally. **The issued item is no longer in your
      inventory.** Check the item, not just the count.
- [ ] **There is no reclaim line, and no shortfall to interpret.** The old
      per-round ledger is gone: the exit clears the player's whole inventory
      — issued, looted, scavenged off the floor, all of it — and hands their
      own stash back, so there is nothing to reconcile and nothing that can
      come up short. What must not appear is `door: <n> item(s) of <src>'s
      could not be returned and are still in stash <name>`. That one is about
      the player's OWN belongings rather than the arena's rounds, and it means
      a return did not finish — the sweep retries within
      `Config.Loadouts.inventory.returnRetrySeconds`.
- [ ] Bring some of **your own** ammunition of the same item into the next
      match, fire nothing, and leave. You still have your own. The arena takes
      back what it issued and no more.
- [ ] Start a match, leave **mid-round** through the panel. Same result.

**A disconnect does not keep it**

- [ ] Start a match and have the second player **pull their network cable /
      quit to desktop mid-round** rather than leaving cleanly.
- [ ] They reconnect. **The issued item is not in their inventory.** This is
      the test that matters most — a disconnect is how an ammo printer would
      actually be run, and it is the path with no player left to tidy up
      after.
- [ ] **And their OWN inventory is back**, without anybody opening a stash.
      The other half of the same path, and the more expensive one to get
      wrong: handing somebody's belongings back needs a player to hand them
      to, and mid-disconnect there is not one, so it is left in their stash
      and returned afterwards on its own. Give it a minute — the sweep runs
      on `Config.Loadouts.inventory.returnRetrySeconds`, thirty seconds by
      default — and if it still has not, the console says which stash and
      why.
- [ ] Do the same with a **full inventory**: fill their pockets, run a match,
      end it, then drop something. Their own kit arrives on the next sweep.
      An item ox_inventory refuses is never destroyed, and never left in a
      stash for an operator to find by hand.
- [ ] Start another and **restart the resource mid-round** (`restart
      crimson_arena`). Every issued item comes back off every player, before
      anything else in the shutdown runs.
- [ ] Nothing in the console says `door: refusing to drop match <id> — <src>'s
      kit is still stashed at <stash>`. That line means a match record was
      asked to close while this resource still owed somebody their own
      inventory. Refusing is the safe outcome, but read it as a sign that an
      exit path did not finish.

**One interaction only a live server can settle.** Some inventory setups tie a
weapon's in-game round count to the ammo item that backs it. This resource
hands over arena weapons as `ox_inventory` items and takes them back the same
way. If your ammo script reconciles the two, run the "you still have your own"
step above twice before trusting the numbers — that is where a double-count
would show.

### 9. The nasty ones
- [ ] Have a player leave during the **frozen countdown**, after the teleport
      but before weapons go live. They should return to the lobby cleanly, with
      their own gear, and be visible to dispatch again.
- [ ] Have the **host cancel** during that same window.
- [ ] Open the panel, then have somebody start the match while it is open. Your
      mouse must be released.

## If something goes wrong

Turn on `Config.Debug = true` and reproduce it — the resource is deliberately
chatty about refusals, escrow and dispatch when that is on. `/arenadispatch`
prints the dispatch report on demand. The README's Troubleshooting section
covers the common causes.

Anything involving money is logged with a `FORFEIT:` or `REFUND FAILED:` prefix
and, where a webhook is configured, sent there regardless of `logPayouts`. If a
pot goes missing, the console already knows why.

## Before you go live

- [ ] `Config.Debug = false`.
- [ ] Betting limits set to numbers that suit your economy, not the shipped
      placeholders.
- [ ] `Config.Permissions.adminGroups` matches your actual admin ACE groups —
      an empty list means nobody can force-stop a stuck match.
- [ ] A backup of your database, if you turned `Config.Database.enabled` on
      and imported the SQL.
- [ ] If ammo types are on: every `item` name in your list is a real item, you
      have seen the **Ammo types** section pass, and `inventory.stripOnEntry` is
  still `true`. Turning
      that one off makes the arena a source of free ammunition — which is a
      decision, not a default.

# Deploying Crimson Arena

Read this before the resource goes anywhere near players.

## The honest status of this build

Everything that can be checked without a running FiveM server has been checked:
every Lua file parses, `luacheck` is clean across the resource, and the spec
suite exercises the real production files under plain Lua 5.4 — the rules, the
payout arithmetic, the escrow invariants, the locale coverage.

**None of it has ever loaded into FXServer.** No ped has spawned, no panel has
opened, no weapon has been handed out, no routing bucket has replicated. Tests
prove the *rules* are right. They cannot prove the *natives* behave, because
there are no natives outside the game.

So: the smoke test below is not a formality. It is the part of the verification
that this build has not had, and it takes about twenty minutes — half an hour
if you have switched ammo types on, which adds a section of its own.

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
   need them, so a server missing one still starts: the marker replaces the
   NPC, nobody is issued ammo items, and the leaderboard covers the server
   run. Each says so once in the console.
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
- `Config.Arenas.*.spawns` — likewise. The two shipped arenas are open ground
  at real GTA locations (Sandy Shores Airfield and Vespucci beach), chosen so a
  fight has room and sightlines. The coordinates are a starting point: stand
  where you want a spawn and take your own. The config carries a copy-paste
  block for adding more.
- `Config.Betting` — decide whether money is in play at all before players can
  stake it. `Config.Betting.enabled = false` if you are unsure.

Two things ship **off** and stay off unless you decide otherwise. Neither is a
placeholder you have to fix; both are switches you have to mean:

- `Config.Database.enabled` — off, so the leaderboard lives in memory for the
  length of the server run and resets on restart. Nothing else reads the
  database. Turn it on for an all-time board.
- `Config.Loadouts.ammoItems.enabled` — off, because the item names in
  `Config.Loadouts.defaultAmmoTypes` are placeholders (`ammo-rifle`,
  `ammo-rifle-ap`, …) and handing out an item name that does not exist is a
  silent nothing that players report as the arena being broken. If you run an
  ammo script whose types are inventory items, put **your** names in that list
  and then flip the switch — and test it with section 6 below, because it is
  the only part of this resource that touches a player's inventory.

## The smoke test

Run this on a development server, with at least two accounts. Each step names
what to watch for, because most failures here are silent.

### 1. It starts
- [ ] Console shows no Lua error on `ensure crimson_arena`.
- [ ] The config validator printed nothing, or printed only things you expect.
- [ ] The dispatch report lists your real dispatch and ambulance scripts. If it
      says nothing was detected and you know you run one, the resource does not
      recognise its name — add it, or use the hooks.

### 2. The lobby
- [ ] The NPC is standing where you put it, not floating or sunk.
- [ ] Your target script offers the arena option on it.
- [ ] The panel opens, and your mouse works in it.
- [ ] **Press ESC. The panel closes and your mouse returns to the game.** A
      stuck cursor here is the single most disruptive failure this resource can
      have; check it before anything else.

### 3. A match, two players
- [ ] Create a match, second player joins, both see each other in the roster.
- [ ] Pick a weapon and an ammo amount. Pick a team if the mode has them.
- [ ] Start it. Both players are teleported, frozen, then released together.
- [ ] **You have exactly the weapon and ammo you chose — no more.** If you
      brought your own gun in, it is gone (`stripWeaponsOnEntry`).
- [ ] Kill each other. The HUD scoreboard updates.
- [ ] The match ends, both are returned to `returnCoords`, and **your own
      weapons and armour are back**. Losing a player's inventory is the
      unforgivable failure; verify it deliberately rather than assuming.

### 4. Dispatch — the reason most of this exists
- [ ] Fire a weapon inside the arena. **Your police script gets no call.**
- [ ] Die inside the arena. **Your ambulance script gets no call, and no medic
      is paged.**
- [ ] Have a third player stand outside the arena. They cannot see or hear the
      fight (routing-bucket isolation).
- [ ] Leave the arena and fire a weapon in town. **Your police script DOES get
      a call.** This is the test people skip, and it is the one that catches a
      suppression flag that leaked — a player who stays permanently invisible to
      dispatch is far worse than one who never was.

### 5. Money, if betting is on
- [ ] Join with a stake. It leaves your account immediately.
- [ ] Win. The pot arrives, and the arithmetic is what you expected.
- [ ] Start another, then have a player **disconnect mid-round**. Check the
      remaining players are paid and nothing is stranded.
- [ ] Start another and **restart the resource mid-round** (`restart
      crimson_arena`). Every stake must come back. Every player must be back in
      the world, visible, with their own gear.

### 6. Ammo types, if you switched them on

Skip this whole section if `Config.Loadouts.ammoItems.enabled` is `false` —
nothing below can happen. If it is `true`, do not skip any of it: this is the
only code in the resource that puts an item into a player's inventory, which
makes it the only code that can duplicate one. An arena that hands out
ammunition and does not take it back is an ammo printer.

Run it with `Config.Debug = true` so the grant and the reclaim both print, and
keep the inventory UI open next to you.

**The right item arrives**

- [ ] Pick one type deliberately — say Armour Piercing on the Assault Rifle —
      and note which item name your config maps it to.
- [ ] Start the match. **That exact item is in your inventory**, in the amount
      your ammo count and `roundsPerItem` call for. 60 rounds at
      `roundsPerItem = 1` is 60 items; at 30 it is 2, and 61 rounds is 3,
      because the division rounds up.
- [ ] The console shows `ammo: gave <item> x<n> to <src> on match <id>`.
- [ ] **No `could not give` line.** One of those names an item that does not
      exist on your server, or an inventory that was full — it is the only
      place a wrong item name ever shows up, since nothing validates the names
      at startup.
- [ ] Pick a **different** type and start again. A different item arrives. If
      both types give you the same item, two entries in your list are pointing
      at the same name.
- [ ] Take a **melee weapon** and start. No ammo item is issued and no type was
      ever offered — melee is excluded automatically.
- [ ] Take an **MK II weapon** and start. Those four ship with their own
      `ammoTypes` list carrying components and no `item` names, and a
      per-weapon list replaces the shared one — so if you edited only
      `defaultAmmoTypes`, MK II weapons hand out a magazine and no item. Either
      that is what you meant, or those four lists need your item names too.

**It is gone after the match**

- [ ] Finish the round normally. **The issued item is no longer in your
      inventory.** Check the item, not just the count.
- [ ] Console: `ammo: reclaimed <n> of <m> item(s)`. A shortfall here is
      ammunition you fired — it cannot come back and that is expected. What
      must not appear is a `could not be taken back` line for rounds you never
      spent.
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
- [ ] Start another and **restart the resource mid-round** (`restart
      crimson_arena`). Every issued item comes back off every player, before
      anything else in the shutdown runs.
- [ ] Nothing in the console says `refusing to drop match ... still holds`.
      That line means a match record was closed with ammunition outstanding.

**One interaction only a live server can settle.** Some inventory setups tie a
weapon's in-game round count to the ammo item that backs it. This resource
grants weapons with the game's own natives and strips them on entry
(`Config.Match.stripWeaponsOnEntry`), which is a separate mechanism from the
item ledger. If your ammo script reconciles the two, run the "you still have
your own" step above twice before trusting the numbers — that is where a
double-count would show.

### 7. The nasty ones
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
      have seen section 6 pass, and `inventory.stripOnEntry` is still `true`. Turning
      that one off makes the arena a source of free ammunition — which is a
      decision, not a default.

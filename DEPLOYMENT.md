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
that this build has not had, and it takes about twenty minutes.

## Install

1. Drop the folder into your resources directory as `crimson_arena`. **The
   folder name matters** — the NUI page is served from `nui://crimson_arena/`
   and the exports are registered under it. Renaming it breaks both.
2. `ensure crimson_arena` in your `server.cfg`, after `qbx_core`, `ox_lib`,
   `ox_target` and `oxmysql`.
3. Optionally import `sql/install.sql`. You do not have to — the resource
   creates its one table itself on first start. Import it if your database user
   cannot `CREATE TABLE` at runtime, which is a reasonable way to run a
   production server.
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

### 6. The nasty ones
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
- [ ] A backup of your database, if you imported the SQL.

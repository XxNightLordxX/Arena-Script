# Crimson Arena — Feature and Function Reference

*Everything this resource does, and every function it does it with.*

`README.md` explains how to run the arena and `DEPLOYMENT.md` is the checklist for
putting it on a live server. This file is the inventory: what the resource does,
what it exposes to other scripts, and every public function in every file with a
line on what it is for. It is written to be read start to finish or searched.

Version 1.0.0 · author John Allday · `crimson_arena`

---

## Contents

- [What it is](#what-it-is)
- [Features](#features)
- [What ships switched on](#what-ships-switched-on)
- [Commands](#commands)
- [Exports for other resources](#exports-for-other-resources)
- [Events other resources can listen for](#events-other-resources-can-listen-for)
- [The network surface](#the-network-surface)
- [Configuration map](#configuration-map)
- [File map](#file-map)
- [Function reference](#function-reference)

---

## What it is

A player-run PvP arena for Qbox. A player walks up to a lobby ped, opens a panel,
opens a match, picks an arena, a mode, a weapon loadout and an amount of
ammunition, and other players join them. When everybody is ready the round is
fought inside its own network instance, scored, paid out, and everyone is put back
exactly where they were with exactly what they were carrying.

The two things it is careful about are the two things a PvP script can get wrong in
a way nobody forgives: **a player's belongings**, and **the rest of the server**. A
player's own inventory is stowed in a stash keyed to their character and handed
back on every exit path there is, including a disconnect and a server restart. A
match is fought in its own routing bucket, so nobody outside it can see it, hear
it, walk into it or be shot by it — and the resource now measures whether that
instancing really happened rather than assuming it did.

---

## Features

### Matches

- **Player-run lobbies.** Any player who passes `Config.Permissions.createJobs`
  opens a match from the panel; others browse and join. No admin has to be online.
- **Free-for-all and team deathmatch.** A mode decides whether teams exist,
  whether friendly fire lands, and what ends the round.
- **Uneven teams are allowed on purpose.** The startability rule is that every
  enabled team has somebody in it, not that the sides are equal.
- **Lives, not one death.** The host picks how many, inside a band the operator
  sets. Losing your last one eliminates you; losing one before that respawns you
  at the point furthest from everyone still alive.
- **Win conditions:** last standing, a score limit, or a round timer, per mode.
- **A countdown you can still back out of**, then a frozen countdown once
  everybody is in the arena and armed.
- **Concurrent matches.** Several rounds run at once, each in its own instance,
  and two of them can share one arena because they cannot see each other. If the
  server is not instancing, the second match at a busy arena is refused rather
  than dropped on top of the first.
- **Every exit is the same exit.** Winning, being eliminated, walking out, being
  dropped, an admin stop and a resource restart all route through one function, so
  none of them can forget the flag, the bucket, the money or the inventory.

### Arenas

- **Two shipped arenas, both enabled**: *The Skydome*, a walled platform built a
  kilometre up with nothing under it and nothing over it, and *Trailer Park*, a
  fought-in corner of the real map. Two more ship switched off.
- **Arenas that build themselves.** An arena can carry its own floor and its own
  cover as props: the client builds them on entry and takes them down on exit,
  and sweeps for anything a crash left standing.
- **The skydome is walled in** with double-stacked shipping containers so nobody
  falls off, spread and angled rather than laid out in a ring.
- **Arenas grow with the roster.** One factor scales the spawn area, the floor and
  the boundary together, so twenty fighters are not placed in a circle sized for
  six.
- **Planned spawns.** The whole roster is placed at once, kept a minimum distance
  apart and clear of the arena's own cover, rather than each player being scattered
  independently and hoping.
- **A boundary that pushes back**, and a keep-out fence that stops outsiders
  wandering into ground a round is being fought on — with the arena you are
  *watching* exempted, so a spectator is not fenced out of the fight.

### Weapons, ammunition and inventory

- **96 weapons catalogued, 77 enabled**, in categories, with per-weapon slots for
  primary, secondary and melee.
- **The host or the player picks**, per `Config.Loadouts.chooser`.
- **You pick an amount of ammunition, not a type.** The correct ammo item for that
  weapon is worked out and handed over automatically: one magazine loaded in the
  gun, the rest as items, totalling exactly what was picked.
- **Full health and a full plate on every life, by rule** — not a config key, not a field a client can send.
- **Choosable spare kit**: extra armour plates and bandages, per-item maximums and a shared ceiling, issued as real items and reclaimed against what the player still holds.
- **The door.** A player's own inventory is stowed in a stash keyed to their
  citizen id — so a reconnect finds it and a recycled server id cannot open it —
  and handed back on the way out.
- **It hands back automatically, and keeps trying.** A return that fails because
  the player's inventory is full, or because they disconnected, or because the
  server restarted mid-match, is retried on a timer; the debt is keyed to the
  character, so a new server id is not a new person.
- **Nothing is destroyed on a guess.** Every write is proved before the thing it
  replaces is removed.

### Betting

- **Entry fees** into an escrowed pot, from cash or bank — the player picks which.
- **Side bets** from spectators, and fighters may back themselves, each with their
  own enabled/min/max band.
- **Payout modes**: `winner_takes_all` — one player, or the winning team splitting
  it evenly — or `per_kill`, divided by share of the kills. Anything else is read
  as `winner_takes_all`, so a typo cannot swallow a pot.
  Side-bet pools settle in proportion to what each backer staked. A configurable
  house cut, and integer maths that distributes every remaining dollar rather than
  dropping it.
- **Refunds are the default on anything that is not a fought round** — a cancelled
  lobby, a disconnect before the start, an aborted match — each with its own
  switch.

### Spectating

- **Watch from the panel**, or automatically when you lose your last life.
- **The viewer is put in the match's instance and moved to the arena**, because
  entity streaming follows the player's body and not the camera — watch from
  outside without that and the round is an empty room.
- **Cycle through living fighters**, with the target list rebuilt as people are
  eliminated.

### The rest of the server

- **Routing-bucket isolation**, one bucket per match. Nobody outside the match
  sees the fighters, the gunfire or the bodies, and no dispatch or ambulance
  script running on their client has anything to report.
- **It is measured, not assumed.** A bucket is set and read back; if the server
  says the player is somewhere else, the resource says so once, loudly, and stops
  claiming isolation for the rest of the run. `/arenaisolation` prints the
  readings.
- **A dispatch integration in five layers**, from the one that needs nobody's
  cooperation down to the one that admits it is best-effort — plus a catalogue
  that detects the police and EMS resources actually running and a startup report
  that says, per resource, whether the arena reaches it.
- **The arena does not revive players itself.** It stopped: two resources writing to one body is a flicker with a winner, not a revive. Its own death handling stands the ped up in the frame it dies, and the medical script's revive — fired automatically for every script the catalogue detects — is what clears that script's casualty list.
- **A crossfire guard**, so a shot fired inside the arena cannot hurt somebody
  outside it and vice versa.

### Operator surface

- **A leaderboard**, in memory by default; switch `Config.Database` on and it is
  written to MySQL through oxmysql and survives restarts.
- **Discord webhooks** for matches and money movements.
- **A config validator** that runs at start in both realms and names every problem
  it finds rather than throwing.
- **Rate limiting on every client entry point**, and every payload rebuilt from
  scalars on arrival rather than trusted.
- **63 spec files** covering the shared, server and client logic, run with `lua5.4`
  against a fake-native harness.

---

## What ships switched on

| | Enabled | Also in the catalogue, switched off |
|---|---|---|
| Arenas | **The Skydome** (`skydome`), **Trailer Park** (`trailerpark`) | — |
| Modes | **Free For All** (`ffa`, the default), **Team Deathmatch** (`tdm`) | — |
| Teams | **Crimson** (`crimson`), **Ash** (`ash`) | Bone (`bone`), Ember (`ember`) |
| Weapons | 77 | 19 |

Other shipped defaults worth knowing: betting **on** (entry fees, spectator bets
and fighter bets all on), the leaderboard database **off** (so the board covers the
current server run), webhooks **off**, `Config.Debug` **on**, loadouts chosen by
the **host**, ammunition items **on**, the inventory door **on**, minimum 2 players,
no maximum, no cap on concurrent matches, and `last_standing` as the win condition.

---

## Commands

All four are gated on `Config.Permissions.adminGroups`; the server console always
qualifies.

| Command | What it does |
|---|---|
| `/arenaadmin` | Lists live matches and force-stops one, refunding everybody. |
| `/arenadispatch` | Re-runs the police/EMS detection and prints the whole startup report, live, without a restart. |
| `/arenarevive <id>` | Runs the end-of-match medical handoff against any player on demand, so it can be tested without playing a round. |
| `/arenaisolation` | Prints what instancing is really doing: the mode the server reports for `onesync`, whether a routing bucket has been caught not landing, the bucket each live match was allocated, and the bucket the server says each of those players is standing in right now. |

**No player-facing slash command ships.** The panel opens from the lobby ped or
the ground marker, whichever `Config.Lobby.interaction` names. `Config.UI.command`
is `nil`; set it to a name like `'arena'` if you want a command as well, which is
mostly useful for testing.

---

## Exports for other resources

**Server**

| Export | Returns |
|---|---|
| `exports.crimson_arena:IsPlayerInArena(src)` | Whether that player is in a match right now. |
| `exports.crimson_arena:GetPlayerMatchId(src)` | The match id they are in, or nil. |
| `exports.crimson_arena:GetArenaPlayers()` | Every player in a match, as a `src -> matchId` map. A copy. |

**Client**

| Export | Returns |
|---|---|
| `exports.crimson_arena:IsInArena()` | Whether this player is in a match. |
| `exports.crimson_arena:GetArenaMatchId()` | The match id, or nil. |

**State bag**, readable from either realm with no call and no event:

```lua
if Player(src).state.crimsonArena then return end        -- server
if LocalPlayer.state.crimsonArena then return end        -- client
```

---

## Events other resources can listen for

Both are **server** events, and both are configurable in
`Config.Dispatch.custom` (set either to `nil` to fire nothing).

| Event | Fired when |
|---|---|
| `crimson_arena:dispatch:enter(src, matchId)` | A player is placed in an arena. |
| `crimson_arena:dispatch:exit(src, matchId)` | A player leaves one, by any path. |

---

## The network surface

**Client → server** — every one of them rate-limited, and every payload rebuilt
from scalars on arrival:

`panelClosed`, `requestState`, `createMatch`, `joinMatch`, `leaveMatch`, `setTeam`,
`setLoadout`, `setReady`, `startMatch`, `holdCountdown`, `cancelMatch`,
`updateMatch`, `reportDeath`, `spectateMatch`, `stopSpectating`,
`placeSpectatorBet` — all prefixed `crimson_arena:server:`.

**Callback:** `crimson_arena:server:getState` — the panel's opening snapshot.

**Server → client**, all prefixed `crimson_arena:client:`:

`state`, `enterArena`, `exitArena`, `matchLive`, `matchHud`, `countdown`,
`results`, `eliminated`, `respawn`, `revive`, `notify`, `closePanel`,
`gunGameRung`, `runCommand`.

---

## Configuration map

`config.lua` is one file, heavily commented, and its own header carries a
line-number map that is regenerated whenever the file changes.

| Block | What it governs |
|---|---|
| `Config.ResourceLabel`, `Config.Debug`, `Config.NotifyTitle` | Naming and the debug channel. |
| `Config.Lobby` | The lobby ped, the ground marker, the blip, how players interact with it, and where they are returned to. |
| `Config.Match` | Player counts, lives, countdowns, win conditions, respawn timing, spawn scatter, the keep-out barrier, the crossfire guard, the radar, and the rules about being dead or in a vehicle. |
| `Config.Teams` | The team list, their colours and their order. |
| `Config.Modes`, `Config.DefaultMode` | Free-for-all and team deathmatch: whether teams exist, what ends a round. |
| `Config.Betting` | Entry fees, spectator bets, fighter bets, payout mode, house cut, which accounts may be used, and every refund rule. |
| `Config.UI` | Panel title, subtitle, logo, theme, sounds, and whether the in-match HUD is drawn. |
| `Config.Permissions` | Admin groups, and the jobs allowed to create or join matches. |
| `Config.Arenas` | Every arena: where it is, its boundary, its spawn points or spawn area, the floor and cover it builds, and how it scales with the roster. |
| `Config.Loadouts` | The weapon catalogue, categories, slots, ammunition amounts and types, armour, the loadout chooser, and the inventory door. |
| `Config.Database` | The oxmysql-backed leaderboard, off by default. |
| `Config.Webhook` | Discord embeds for matches and money. |
| `Config.Dispatch` | Routing-bucket isolation first, then the five layers of police/EMS integration and the arena's own revive. |

---

## File map

| File | Realm | What lives there |
|---|---|---|
| `config.lua` | shared | Everything an operator edits, except the weapon catalogue. |
| `config.weapons.lua` | shared | The weapon catalogue. Loaded straight after `config.lua` and writes `Config.Loadouts.weapons` into it. |
| `shared/arena.lua` | shared | The rules: the catalogue readers, the validators, the spawn and payout maths. No side effects. |
| `shared/compat/dispatch.lua` | shared | The police/EMS catalogue, the detection walk, the mutes and the startup report. |
| `server/util.lua` | server | Logging, notifications, permissions, rate limiting, webhooks, match ids. |
| `server/dispatch.lua` | server | The in-arena flag, routing-bucket isolation, the revive, and `/arenarevive` and `/arenaisolation`. |
| `server/ammo.lua` | server | The inventory door and every ammunition item, issued and reclaimed. |
| `server/stats.lua` | server | The leaderboard, in memory and in MySQL. |
| `server/betting.lua` | server | Escrow, side bets, refunds and payouts. |
| `server/lobby.lua` | server | The match registry, joining, leaving, readiness and the state snapshot. |
| `server/match.lua` | server | The round itself: start, deaths, respawns, the end, and the instancing sweep. |
| `server/main.lua` | server | Every client entry point, its validation and its rate limit. |
| `client/ui.lua` | client | The NUI bridge. |
| `client/dispatch.lua` | client | Client-side suppression and the arena's own revive. |
| `client/main.lua` | client | The lobby ped, the marker, the blip and the cached state. |
| `client/match.lua` | client | Being in a round: the loadout, the boundary, the props, the blips and outlines, the HUD. |
| `client/spectate.lua` | client | The spectate camera and its target list. |
| `html/` | — | The panel. |
| `locales/` | — | Every player-visible string. |
| `sql/install.sql` | — | The leaderboard table, for operators who import by hand. |
| `tests/` | — | 63 spec files and the fake-native harness they run against. |

---

## Function reference

Every function each file exposes, in the order it is defined. Local helpers are not
listed; the source documents them where they are.

#### `shared/arena.lua` — 61 functions

| Function | What it does |
|---|---|
| `Arena.ToInt(value)` | Rounds toward zero and returns an integer. |
| `Arena.ClampInt(value, minimum, maximum)` | Clamps `value` into [`minimum`, `maximum`] as an integer. |
| `Arena.IsKey(value)` | True only for a non-empty string. |
| `Arena.IsPoint(value)` | Whether a value is shaped like a coordinate this resource can read. |
| `Arena.CoverClearance(arenaKey)` | The clearance this arena keeps around its cover. |
| `Arena.TangentHeading(dx, dy, longIsX)` | The heading that lays a piece's LONG side across the radius rather than along it -- side-on to the middle of the arena, which is what makes a ring of containers a wall instead of a set of spokes. |
| `Arena.Count(tbl)` | How many entries a table holds, including string keys. |
| `Arena.GetEnabledWeapons()` | Every weapon an operator has left switched on, in config order. |
| `Arena.GetWeaponByKey(key)` | The one weapon with this key, or nil. |
| `Arena.GetEnabledTeams()` | Enabled teams, sorted by their `order` then key so every client renders the picker in the same sequence. |
| `Arena.GetTeamByKey(key)` | One enabled team by key, or nil. |
| `Arena.GetEnabledArenas()` | Every arena an operator has left switched on, in config order. |
| `Arena.GetArenaByKey(key)` | One enabled arena by key, or nil. |
| `Arena.GetEnabledModes()` | Every mode an operator has left switched on, in config order. |
| `Arena.GetModeByKey(key)` | One enabled mode by key, or nil. |
| `Arena.ModeUsesTeams(modeKey)` | True when this mode puts players on sides. |
| `Arena.GetAmmoOptions(weapon)` | The ammo values the panel offers for one weapon. |
| `Arena.AllowsCustomAmmo(weapon)` | Whether a player may type their own ammunition amount rather than being held to the preset list. |
| `Arena.ResolveAmmo(weapon, requested)` | Turns whatever a client asked for into an ammo count the server is willing to hand out. |
| `Arena.IsMeleeWeapon(weapon)` | Whether a weapon is melee, which is the one distinction this resource draws between kinds of weapon. |
| `Arena.GetAmmoTypes(weapon)` | The ammo types on offer for one weapon: its own list, or the shared default, or none. |
| `Arena.AllAmmoItems()` | Every item name any ammo type in the catalogue can hand out, deduplicated. |
| `Arena.ResolveAmmoType(weapon, requested)` | Turns whatever ammo type a client asked for into one this server is willing to load. |
| `Arena.MagazineFor(weapon, rounds)` | What a weapon starts LOADED with, when the rest of the rounds a player picked are handed over as inventory items instead. |
| `Arena.StartingVitals()` | The health and armour every fighter starts every life on — a rule, not a setting. |
| `Arena.GetEnabledSupplies()` | Every extra supply an operator has left switched on, in config order. |
| `Arena.SupplyMax(supply)` | The most of one supply a player may carry in. |
| `Arena.ResolveSupplies(requested)` | Turns whatever a client asked to carry into a list the server will hand over. |
| `Arena.ResolveLoadout(request)` | Validates a whole loadout request and returns the concrete thing to hand a player -- real GTA weapon names and real ammo counts, nothing the caller supplied passed through untouched. |
| `Arena.CountTeams(players)` | Head count per team, from a list of players. |
| `Arena.SuggestTeam(players)` | The team a newly joining player should land on when they did not pick one: the smallest enabled team WITH ROOM IN IT, ties broken by config order so the choice is deterministic rather than dependent on pairs() ordering. |
| `Arena.TeamsAreStartable(players)` | Whether a team match may start with these sides. |
| `Arena.CanDamage(modeKey, attackerTeam, victimTeam)` | Whether one player may hurt another. |
| `Arena.PickSpawn(arenaKey, teamKey, index)` | Picks the spawn point for the `index`-th player (1-based) on a team. |
| `Arena.ModelChain(entry)` | A prop and its stand-ins, as a list to try in order. |
| `Arena.GetPlatform(arenaKey, factor)` | THE FLOOR AN ARENA BRINGS WITH IT. |
| `Arena.PlatformTiles(platform, centreX, centreY, measured)` | Every point one platform's pieces go, worked out from its two numbers. |
| `Arena.GetCover(arenaKey, factor)` | THE COVER AN ARENA BRINGS WITH IT: barriers, blocks, crates. |
| `Arena.ArenaProps(arenaKey, measured, factor)` | EVERYTHING AN ARENA HAS TO BUILD, in world coordinates: the tiled floor and the cover on top of it, as one list. |
| `Arena.PropSweep(arenaKey, factor)` | EVERYTHING THIS ARENA COULD HAVE LEFT STANDING: where to look for its scenery, how far out, and which models count as its own. |
| `Arena.SpawnFloor(arenaKey)` | The lowest Z a fighter may legitimately be placed at in this arena, or nil where the ground answers that question. |
| `Arena.SpectateFocus(arenaKey)` | Where a spectator's streamer should be pointed to see this arena. |
| `Arena.UsesExactSpawnZ(arenaKey)` | Whether an arena's spawn Z is exact, rather than a hint to search from. |
| `Arena.SizeFactor(arenaKey, players)` | HOW MUCH BIGGER THIS ARENA IS FOR THIS MATCH. |
| `Arena.GetSpawnArea(arenaKey, factor)` | The spawn AREA an arena defines, if it defines one. |
| `Arena.PlanSpawns(arenaKey, roster, rng, factor)` | Works out where every player in a roster starts. |
| `Arena.PickRespawn(arenaKey, teamKey, avoid, rng, factor)` | Where to put a player who has just lost a life. |
| `Arena.ResolveLives(requested)` | How many lives a host may give a match, resolved from what they asked for. |
| `Arena.ResolveRadar(requested)` | Whether a match runs a radar, resolved from what the host asked for. |
| `Arena.ResolveEntryFee(requested)` | Clamps a requested entry fee into the configured band. |
| `Arena.ResolveSpectatorBet(requested)` | A spectator's side-bet, held to the spectator band. |
| `Arena.ResolveFighterBet(requested)` | A FIGHTER'S OWN STAKE, held to the fighter band rather than the spectator one. |
| `Arena.ApplyHouseCut(pot)` | The house cut, and what is left to pay out. |
| `Arena.SplitEvenly(amount, count)` | Splits `amount` between `count` recipients as evenly as integers allow, handing the remainder out one unit at a time from the front. |
| `Arena.SplitByPercent(amount, percents)` | Splits `amount` by a list of percentages, again losing nothing: whatever rounding leaves over goes to the first recipient. |
| `Arena.HexToRgb(hex)` | A team's panel colour as three 0-255 channels. |
| `Arena.SplitByStake(pool, stakes)` | Splits a POOL among winners in proportion to what each of them staked. |
| `Arena.ComputePayouts(context)` | Works out who gets paid what when a match ends. |
| `Arena.ComputeSpectatorPayout(stake)` | What one winning spectator side-bet pays back, stake included. |
| `Arena.CanStartMatch(match)` | Whether a lobby may start. |
| `Arena.HasRoom(currentCount)` | Whether one more player will fit. |
| `Arena.LoadoutChooser()` | Who picks the loadout everyone fights with. |
| `Arena.ValidateConfig()` | Walks the whole config and returns everything wrong with it, by name. |
| `Arena.ReportConfigProblems()` | Prints whatever ValidateConfig found. |

#### `shared/compat/dispatch.lua` — 7 functions

| Function | What it does |
|---|---|
| `ArenaCompat.RegisterAdapter(adapter)` | Adds one adapter to the catalogue. |
| `ArenaCompat.StartedBeforeUs()` | Catalogued emergency resources that were already running when the arena loaded, and therefore registered their death handler first. |
| `ArenaCompat.WarnLateStartOnce()` | SAID AGAIN, AT THE MOMENT IT BITES. |
| `ArenaCompat.Detect()` | Every catalogued resource that is running right now, in catalogue order. |
| `ArenaCompat.ReviveClientEvents()` | The client events that clear a RUNNING medical script's own death record. |
| `ArenaCompat.Mute(src, active)` | Calls every detected adapter's mute, if it has one. |
| `ArenaCompat.Report()` | The startup block, as lines. |

#### `server/util.lua` — 13 functions

| Function | What it does |
|---|---|
| `ArenaLog(fmt, ...)` | Console line an operator will always see. |
| `ArenaDebug(fmt, ...)` | The chatty half. |
| `ArenaNotify(src, description, notifyType)` | One player-visible message, handed to client/ui.lua to place. |
| `ArenaNotifyKey(src, localeKey, notifyType, ...)` | The form almost every caller wants: Arena.* hands back locale KEYS, not sentences, and they go straight through here. |
| `ArenaGetPlayer(src)` | The qbx_core player object for a server id, or nil. |
| `ArenaPlayerName(src)` | Never nil. |
| `ArenaIsAdmin(src)` | ACE check against Config.Permissions.adminGroups. |
| `ArenaCanCreate(src)` | Whether this player may open a lobby, per Config.Permissions.createJobs. |
| `ArenaCanJoin(src)` | The same question asked of somebody joining a match they did not open. |
| `ArenaRateLimit(src, bucket, intervalMs)` | Whether this call is inside the interval for that bucket; false throttles it. |
| `ArenaForgetPlayer(src)` | Drops one player's rate-limit history; main.lua calls it from playerDropped. |
| `ArenaWebhook(title, description, fields)` | Posts one embed to the configured Discord webhook. |
| `ArenaNewId()` | A fresh match id, unique for this server run. |

#### `server/dispatch.lua` — 12 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.Set(src, matchId)` | Marks a player as being in `matchId`. |
| `ArenaDispatch.Clear(src)` | Clears the flag. |
| `ArenaDispatch.ClearDownState(src)` | Puts the medical script's down flags back down, at the death rather than at the revive. |
| `ArenaDispatch.HoldDownState()` | One pass: the flags put back down for everybody currently in a match. |
| `ArenaDispatch.Revive(src, keepHold)` | Tells whatever handles death on this server that a player is alive again. |
| `ArenaDispatch.IsPlayerInArena(src)` | Whether the server has this player flagged as being in a match. |
| `ArenaDispatch.GetPlayerMatchId(src)` | The match a flagged player is in, or nil. |
| `ArenaDispatch.GetArenaPlayers()` | Every player currently in a match, as a server-id -> match-id map. |
| `ArenaDispatch.OneSync()` | The mode, for the startup report -- which has to describe what the server IS rather than what config asked for. |
| `ArenaDispatch.GetBucket(matchId)` | The instance a match is fought in, allocating and configuring one the first time it is asked for. |
| `ArenaDispatch.EnterBucket(src, matchId)` | Moves a player into their match's instance, remembering what they were in beforehand. |
| `ArenaDispatch.ExitBucket(src)` | Puts a player back in exactly the bucket EnterBucket found them in, and hands the match's number back once the last person has left it. |
| `ArenaDispatch.ReleaseBucket(matchId)` | Gives a match's bucket number back to the pool. |
| `ArenaDispatch.IsolationState()` | What isolation is ACTUALLY doing right now, for the startup report and for /arenaisolation. |

#### `server/ammo.lua` — 12 functions

| Function | What it does |
|---|---|
| `ArenaAmmo.IsEnabled()` | Whether ammunition ITEMS are being handed out. |
| `ArenaAmmo.SwapWeapon(src, matchId, removeWeapon, addWeapon, rounds)` | Swaps one arena weapon for another, as items. |
| `ArenaAmmo.Issue(src, matchId, loadout)` | Puts the player's own kit away, then gives them what the loadout says. |
| `ArenaAmmo.Reclaim(src, reasonKey)` | Destroys the arena kit and hands the player's own inventory back. |
| `ArenaAmmo.ReclaimAll(matchId, reasonKey)` | Reclaims the kit of every player in one match. |
| `ArenaAmmo.Clear(matchId)` | Drops a match's record. |
| `ArenaAmmo.OnLoan(matchId)` | How many rounds one match is still on the hook for. |
| `ArenaAmmo.IsHolding(src)` | Whether this resource is currently holding this player's inventory. |
| `ArenaAmmo.StashOf(src)` | The stash a player's kit is in, for an admin who needs to point them at it. |
| `ArenaAmmo.ReturnLeftovers(src)` | Hands back anything of this player's still sitting in their arena stash. |
| `ArenaAmmo.SweepReturns()` | One pass over everybody on the server. |
| `ArenaAmmo.Owed()` | How many characters this resource still owes belongings to. |

#### `server/stats.lua` — 5 functions

| Function | What it does |
|---|---|
| `ArenaStats.Record(entry)` | Folds one player's finished match into the totals. |
| `ArenaStats.RecordMatch(match)` | Records every player of a finished match in one call. |
| `ArenaStats.GetLeaderboard(cb)` | Hands the top rows to `cb`. |
| `ArenaStats.Flush()` | Writes everything queued and empties the queue. |
| `ArenaStats.EnsureSchema()` | Creates the table if it is not there. |

#### `server/betting.lua` — 21 functions

| Function | What it does |
|---|---|
| `ArenaBetting.Accounts()` | The accounts a player may be asked to choose between, in the operator's own order. |
| `ArenaBetting.Wallet(src)` | What one player holds in each of them, for the panel's own display. |
| `ArenaBetting.IsRefundReason(reason)` | Whether a payout line is a stake coming back rather than money won. |
| `ArenaBetting.IsEnabled()` | Whether betting is switched on at all. |
| `ArenaBetting.GetPot(matchId)` | What a match is holding right now. |
| `ArenaBetting.GetStake(matchId, src)` | One player's share of the held pot -- 0 once it has been refunded or paid out, because at that point this match holds nothing of theirs. |
| `ArenaBetting.TakeStake(src, matchId, amount, account)` | Takes a player's entry fee and holds it against `matchId`. |
| `ArenaBetting.RefundOne(matchId, src, reasonKey)` | Returns exactly what was taken, exactly once. |
| `ArenaBetting.RefundAll(matchId, reasonKey)` | Everybody still in escrow gets their own stake back -- their own, not an even share of the pot. |
| `ArenaBetting.KeepInPot(matchId, src)` | Keeps one player's stake in the pot rather than handing it back. |
| `ArenaBetting.ForfeitAll(matchId, reasonKey)` | Keeps every held stake and pays nobody. |
| `ArenaBetting.Settle(matchId, context)` | Pays the pot out. |
| `ArenaBetting.GetSideBetPool(matchId)` | Everything staked in side-bets that will be settled as a pool. |
| `ArenaBetting.GetPrizePool(matchId)` | Everything a winner of this match stands to be paid from, as one figure. |
| `ArenaBetting.GetSideBet(matchId, src)` | One player's own side-bet on a match, or nil. |
| `ArenaBetting.HoldsSideBet(matchId, src)` | Whether this player is holding an UNSETTLED side-bet on this match. |
| `ArenaBetting.HasSpectatorBet(matchId, src)` | Whether this player holds any side-bet on this match, settled or not. |
| `ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)` | Takes a spectator's side-bet on a team or a fighter. |
| `ArenaBetting.ReturnSideBets(matchId)` | Hands every unsettled side-bet on a match back, unjudged. |
| `ArenaBetting.SettleSpectatorBets(matchId, winningPick)` | Settles every side-bet on a match. |
| `ArenaBetting.Clear(matchId)` | Drops a match's money state. |

#### `server/lobby.lua` — 21 functions

| Function | What it does |
|---|---|
| `ArenaLobby.Get(matchId)` | One match by id, or nil. |
| `ArenaLobby.GetByPlayer(src)` | The match a player is attached to, or nil. |
| `ArenaLobby.All()` | Oldest first, id breaking the tie, so two reads of an unchanged registry can never render the match list in a different order. |
| `ArenaLobby.PlayerCount(match)` | How many players a match has seated. |
| `ArenaLobby.PlayerArray(match)` | The roster as an ARRAY, in join order -- the shape every Arena.* rule takes, and the order a spawn index is drawn from. |
| `ArenaLobby.BuildState(src)` | The whole snapshot one player is allowed to see: matches, their own row, the leaderboard and their wallet. |
| `ArenaLobby.Broadcast()` | Pushes the snapshot to everyone who can see it and nobody who cannot. |
| `ArenaLobby.MarkPanelOpen(src)` | Records that this player has the panel up, so pushes reach them. |
| `ArenaLobby.MarkPanelClosed(src)` | Records that this player has closed the panel. |
| `ArenaLobby.Create(src, arenaKey, modeKey, entryFee, lives, radar, account)` | Opens a lobby and puts its host in it. |
| `ArenaLobby.Join(src, matchId, teamKey, account)` | Seats a player in an open lobby, taking their entry fee. |
| `ArenaLobby.Leave(src, reasonKey)` | Takes a player out of whatever they are attached to: a match if they are in one, otherwise the match they were watching. |
| `ArenaLobby.Destroy(matchId, reasonKey)` | Refunds whatever is still escrowed, tells everyone, and removes the match from the registry. |
| `ArenaLobby.HoldCountdown(src)` | Puts a counting-down lobby back to being a lobby. |
| `ArenaLobby.Cancel(src)` | The host closing their own lobby. |
| `ArenaLobby.UpdateMatch(src, data)` | Changes the settings of a match the host has already opened. |
| `ArenaLobby.SetTeam(src, teamKey)` | Moves a player to another team in a team mode. |
| `ArenaLobby.SetLoadout(src, request)` | Stores a player's chosen loadout after re-resolving it against the catalogue. |
| `ArenaLobby.SetReady(src, ready)` | Marks a player ready or not ready, and auto-starts when that was the last one. |
| `ArenaLobby.AddSpectator(src, matchId)` | Attaches a watcher to a match and puts them in its instance. |
| `ArenaLobby.RemoveSpectator(src)` | Detaches a watcher and sends them back out. |

#### `server/match.lua` — 9 functions

| Function | What it does |
|---|---|
| `ArenaMatch.Begin(matchId, requestedBy)` | Validates a lobby and runs the countdown players may still back out of. |
| `ArenaMatch.Start(matchId)` | Teleports everybody in, hands out the loadouts, and starts the frozen countdown that ends with weapons live. |
| `ArenaMatch.OnDeath(src, killerSrc)` | One player died. |
| `ArenaMatch.End(matchId, reasonKey, winners)` | Ends a round that was actually fought: decides the winners, settles the money, records it, and sends everybody home with a result. |
| `ArenaMatch.Abort(matchId, reasonKey)` | The refund-everything path: a resource stop, an admin force-stop, a lobby that emptied out, a round that could not start. |
| `ArenaMatch.RemovePlayer(src, reasonKey)` | One player out, mid-round: they left, they were dropped, or an admin pulled them. |
| `ArenaMatch.IsLive(matchId)` | Whether a match is in its live phase. |

#### `client/ui.lua` — 9 functions

| Function | What it does |
|---|---|
| `ArenaUI.Send(action, data)` | Sends the raw `{ action, data }` envelope the panel listens for. |
| `ArenaUI.IsOpen()` | Whether the panel is up on this client. |
| `ArenaUI.SendState(state)` | Pushes a fresh state snapshot into an already-open panel. |
| `ArenaUI.Notify(description, notifyType)` | Player-visible message. |
| `ArenaUI.Open()` | Fetches the snapshot first and only then takes focus: a panel that opens before it has anything to render shows an empty frame with the mouse already captured, and a failed fetch would leave that frame permanent. |
| `ArenaUI.Close()` | Safe to call when already closed; the release is unconditional because releasing focus we do not hold costs nothing and failing to release focus we do hold costs the player their character. |
| `ArenaUI.UpdateHud(data)` | Pushes the in-match scoreboard numbers into the HUD. |
| `ArenaUI.Countdown(seconds, label)` | The big centred number before a round goes live. |
| `ArenaUI.Results(results)` | End-of-match scoreboard. |

#### `client/dispatch.lua` — 8 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.IsInArena()` | Whether this player is currently in an arena match. |
| `ArenaDispatch.MatchId()` | The match this client believes it is in, or nil. |
| `ArenaDispatch.Enter(matchId)` | Silences everything this resource is able to silence, and records what has to be put back. |
| `ArenaDispatch.Exit()` | Undoes Enter(), exactly. |
| `ArenaDispatch.ClearDeadState(ped)` | Puts an arena casualty back on their feet in the same instant they went down, held frozen, invisible and untouchable until the server says what happens next. |
| `ArenaDispatch.ReleaseDeadState(ped)` | Undoes ClearDeadState's holding pattern. |

#### `client/main.lua` — 4 functions

| Function | What it does |
|---|---|
| `ArenaState.Get()` | The whole last-known snapshot, or nil before the first push. |
| `ArenaState.Set(newState)` | Replaces the cache. |
| `ArenaState.MatchId()` | The match this player belongs to, lobby or live, or nil. |
| `ArenaState.IsInMatch()` | Whether this player is attached to a match, lobby or live. |

#### `client/match.lua` — 2 functions

| Function | What it does |
|---|---|
| `ArenaMatch.SetKeepOut(zones)` | Sets the arenas this client is fenced out of because a round it is not in is being fought there. |
| `ArenaMatch.SetRadar(on)` | Set from `enterArena` -- never from the panel, which no longer has a control that reaches this side. |

#### `client/spectate.lua` — 5 functions

| Function | What it does |
|---|---|
| `ArenaSpectate.IsActive()` | Whether the spectate camera is running. |
| `ArenaSpectate.Start(matchIdentifier)` | Starts watching a match, by id or by arena key. |
| `ArenaSpectate.Stop()` | Safe at any time, including when not spectating. |
| `ArenaSpectate.Next()` | Switches to the next living fighter. |
| `ArenaSpectate.Previous()` | Switches to the previous living fighter. |

---

*Generated from the source. If a summary here and the comment above the function disagree, the source is right and this file is stale — say so.*

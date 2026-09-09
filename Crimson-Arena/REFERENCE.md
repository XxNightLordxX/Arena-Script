# Crimson Arena — Feature and Function Reference

> **A SNAPSHOT, AND IT MAY DRIFT.** This file was kept honest by a test —
> `tests/checklist_spec.lua` compared every table below against the real
> files and failed the build when they disagreed. That test has been removed
> with the rest of the suite for release, so from this point on nothing
> checks this document. It was accurate on the day it was written; treat it
> as a map rather than as the territory, and trust the code where the two
> disagree.


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
- **Free-for-all, team deathmatch and gun game**, all three enabled. A mode decides whether teams exist,
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
  fought-in corner of the real map. Nothing ships switched off.
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

- **96 weapons catalogued and all 96 enabled** -- the `heavy` category included, so explosives are pickable. In categories. A player carries
  `Config.Loadouts.slots` of them — guns and melee against one count, so the mix
  is theirs.
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
- **A dispatch integration in six layers**, from the one that needs nobody's
  cooperation down to the one that withdraws a call after it has been filed
  — plus a catalogue
  that detects the police and EMS resources actually running and a startup report
  that says, per resource, whether the arena reaches it.
- **The arena does not revive players itself.** It stopped: two resources writing to one body is a flicker with a winner, not a revive. Its own death handling stands the ped up in the frame it dies, and the medical script's revive — fired automatically for every script the catalogue detects — is what clears that script's casualty list.
- **A crossfire guard**, so a shot fired inside the arena cannot hurt somebody
  outside it and vice versa.
- **The server checks two things for itself**, once a second, because they used
  to be taken from the player's own game on trust: whether a fighter is
  standing anywhere near the arena, and whether one whose body reads as dead
  ever reported it. Both act only on something seen several checks *in a row*
  and never on a body the server cannot see, so a player still streaming the
  world in is not mistaken for a cheat. A death booked this way credits
  nobody. `Config.Match.serverChecks`.

### Operator surface

- **A record of what players still owe the arena** — kit that left with a
  character the exit could not reach — taken back the next time they are seen.
  In memory by default; in MySQL with `Config.Database` on.
- **A leaderboard**, in memory by default; switch `Config.Database` on and it is
  written to MySQL through oxmysql and survives restarts.
- **Discord webhooks** for matches and money movements.
- **A config validator** that runs at start in both realms and names every problem
  it finds rather than throwing.
- **Rate limiting on every client entry point**, and every payload rebuilt from
  scalars on arrival rather than trusted.
- **The test suite is not in this release.** 77 Lua specs and 21 panel
  suites ran green against the code in this folder, comments and all, and
  again after they were stripped -- and were then removed for shipping.
  They are in the repository's history if you want them back.

---

## What ships switched on

| | Enabled | Also in the catalogue, switched off |
|---|---|---|
| Arenas | **The Skydome** (`skydome`), **Trailer Park** (`trailerpark`) | — |
| Modes | **Free For All** (`ffa`, the default), **Team Deathmatch** (`tdm`) | — |
| Teams | **Crimson** (`crimson`), **Ash** (`ash`) | Bone (`bone`), Ember (`ember`) |
| Weapons | 77 | 19 |

Other shipped defaults worth knowing: betting **on** (entry fees, spectator bets
and fighter bets all on), the database **off** (so the board, and the record of what
players still owe the arena, both cover the current server run only), webhooks **off**, `Config.Debug` **on**, loadouts chosen by
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

**No player-facing slash command exists.** The panel opens from the lobby ped or
the ground marker, whichever `Config.Lobby.interaction` names, and there is no
setting that adds a second way in.

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
`results`, `eliminated`, `respawn`, `notify`, `closePanel`, `holdVitals`.

---

## Configuration map

`config.lua` is one file, heavily commented, and its own header carries a
line-number map that is regenerated whenever the file changes.

| Block | What it governs |
|---|---|
| `Config.ResourceLabel`, `Config.Debug`, `Config.NotifyTitle` | Naming and the debug channel. |
| `Config.Lobby` | The lobby ped, the ground marker, the blip, how players interact with it, and where they are returned to. |
| `Config.Match` | Player counts, lives, countdowns, win conditions, respawn timing, spawn scatter, the keep-out barrier, the crossfire guard, the radar, the server-side position and death checks, and the rules about being dead or in a vehicle. |
| `Config.Teams` | The team list, their colours and their order. |
| `Config.Modes`, `Config.DefaultMode` | Free-for-all, team deathmatch and gun game: whether teams exist, what ends a round, and the gun-game ladder. |
| `Config.Betting` | Entry fees, spectator bets, fighter bets, payout mode, house cut, which accounts may be used, and every refund rule. |
| `Config.UI` | Panel title, subtitle, logo, theme, sounds, and whether the in-match HUD is drawn. |
| `Config.Permissions` | Admin groups, and the jobs allowed to create or join matches. |
| `Config.Arenas` | Every arena: where it is, its boundary, its spawn points or spawn area, the floor and cover it builds, and how it scales with the roster. |
| `Config.Loadouts` | Categories, slots, ammunition amounts and types, the extra supplies a player carries in, the loadout chooser, and the inventory door. The weapons themselves are in `config.weapons.lua`. |
| `Config.Database` | The oxmysql-backed leaderboard and the record of what players still owe the arena. Off by default — with it off, both live in memory for one server run. |
| `Config.Webhook` | Discord embeds for matches and money. |
| `Config.Dispatch` | Routing-bucket isolation first, then the layers of police/EMS integration and the timing of the medical handoff. |

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
| `server/ammo.lua` | server | The inventory door, every weapon and ammunition item issued and reclaimed, and the slate of what players still owe the arena. |
| `server/stats.lua` | server | The leaderboard, in memory and in MySQL. |
| `server/betting.lua` | server | Escrow, side bets, refunds and payouts. |
| `server/lobby.lua` | server | The match registry, joining, leaving, readiness and the state snapshot. |
| `server/match.lua` | server | The round itself: start, deaths, respawns, the end, and the instancing sweep. |
| `server/main.lua` | server | Every client entry point, its validation and its rate limit. |
| `client/ui.lua` | client | The NUI bridge. |
| `client/dispatch.lua` | client | Client-side suppression, and holding an arena casualty out of every death poll. |
| `client/main.lua` | client | The lobby ped, the marker, the blip and the cached state. |
| `client/match.lua` | client | Being in a round: the loadout, the boundary, the props, the blips and outlines, the HUD. |
| `client/spectate.lua` | client | The spectate camera and its target list. |
| `html/` | — | The panel. |
| `locales/` | — | Every player-visible string. |
| `sql/install.sql` | — | Both tables — the leaderboard and the outstanding-kit slate — for operators who import by hand. Needs `DELETE` granted as well as `SELECT`/`INSERT`/`UPDATE`. |
| `sql/uninstall.sql` | — | Drops both. Dropping the slate forgives every debt it holds. |

---

## Function reference

Every function each file exposes, in the order it is defined. Local helpers are not
listed; the source documents them where they are.

#### `shared/arena.lua` — 99 functions

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
| `Arena.TeamIndex(teamKey)` | The engine's own team NUMBER for a team key, so friendly fire can be refused before any damage exists. nil off a team. |
| `Arena.GetTeamByKey(key)` | One enabled team by key, or nil. |
| `Arena.GetEnabledArenas()` | Every arena an operator has left switched on, in config order. |
| `Arena.GetArenaByKey(key)` | One enabled arena by key, or nil. |
| `Arena.GetEnabledModes()` | Every mode an operator has left switched on, in config order. |
| `Arena.PlaysLadder(modeKey)` | Whether a mode plays a gun-game ladder at all -- the one answer every caller reads. |
| `Arena.GunGameClasses(modeKey)` | The weapon classes a ladder is built from, with each one's playable pool and ceiling. |
| `Arena.ResolveTierPlan(modeKey, requested)` | A host's requested ladder shape, refused rather than clamped. |
| `Arena.LadderTiersFor(modeKey)` | Every tier of a mode's gun-game ladder that still has a playable weapon in it, in climbing order. |
| `Arena.RoundSecondsFor(modeKey, chosen)` | How long a round of one mode runs: the mode's own clock, falling back to Config.Match's. |
| `Arena.KillCeilingFor(arenaKey, factor)` | How far apart two players may be for one to have killed the other, in this arena. |
| `Arena.WinConditions()` | Every win condition this resource knows, in picker order. |
| `Arena.WinConditionDefault()` | The server-wide win condition, out of a setting that takes a string or a block. |
| `Arena.WinConditionChoice()` | The conditions a host may pick between, or nil where the server fixes it. |
| `Arena.ResolveWinCondition(requested)` | One host's requested win condition, refused rather than clamped. |
| `Arena.WinConditionFor(chosen)` | How one match is won: the host's pick, falling back to the server's. |
| `Arena.ScoreLimitDefault()` | The server-wide kill limit, out of a setting that takes a number or a range. |
| `Arena.ScoreLimitChoice()` | The band a host may name a kill limit within, or nil where the server fixes it. |
| `Arena.ResolveScoreLimit(requested)` | One host's requested kill limit, refused rather than clamped. |
| `Arena.ScoreLimitFor(chosen)` | The limit a match is played to: the host's, falling back to the server's. |
| `Arena.WinConditionSpendsLives(condition)` | Whether a death costs a life under this condition. |
| `Arena.WinConditionNeedsClock(condition)` | Whether only a round clock can settle this condition. |
| `Arena.KillAmmoFor(modeKey)` | How many rounds one verified kill pays for each weapon the killer carries. |
| `Arena.TierAmmoFor(modeKey)` | How many rounds a gun-game tier weapon is handed, or nil for the weapon's own default. |
| `Arena.RoundTimeDefault()` | The server-wide round length, out of a setting that takes a number or a range. |
| `Arena.RoundTimeChoice()` | The range a host may set a round length within, or nil when the choice is not offered. |
| `Arena.ResolveRoundTime(requested)` | How long a host may make a round, refused rather than clamped; 0 means they did not choose. |
| `Arena.GetModeByKey(key)` | One enabled mode by key, or nil. |
| `Arena.ModeUsesTeams(modeKey)` | True when this mode puts players on sides. |
| `Arena.GetAmmoOptions(weapon)` | The ammo values the panel offers for one weapon. |
| `Arena.AllowsCustomAmmo(weapon)` | Whether a player may type their own ammunition amount rather than being held to the preset list. |
| `Arena.ResolveAmmo(weapon, requested)` | Turns whatever a client asked for into an ammo count the server is willing to hand out. |
| `Arena.IsMeleeWeapon(weapon)` | Whether a weapon is melee, which is the one distinction this resource draws between kinds of weapon. |
| `Arena.GetAmmoTypes(weapon)` | The ammo types on offer for one weapon: its own list, or the shared default, or none. |
| `Arena.AllAmmoItems()` | Every item name any ammo type in the catalogue can hand out, deduplicated. |
| `Arena.AllIssuedItems()` | Every item name the arena can put in somebody's hands: weapons, ammunition and supplies. |
| `Arena.ResolveAmmoType(weapon, requested)` | Turns whatever ammo type a client asked for into one this server is willing to load. |
| `Arena.MagazineFor(weapon, rounds)` | What a weapon starts LOADED with, when the rest of the rounds a player picked are handed over as inventory items instead. |
| `Arena.StartingVitals()` | The health and armour every fighter starts every life on — a rule, not a setting. |
| `Arena.GetEnabledSupplies()` | Every extra supply an operator has left switched on, in config order. |
| `Arena.SupplyMax(supply)` | The most of one supply a player may carry in. |
| `Arena.SupplyTotalCap()` | The most supply items of every kind together a player may carry in, or 0 for no ceiling. |
| `Arena.SupplyByKey(key)` | One enabled supply by its key, or nil. |
| `Arena.StartingKitFor(modeKey)` | The supplies a mode hands everybody at the start of a round, whatever they picked -- or nil when it names none. |
| `Arena.ResolveSupplies(requested)` | Turns whatever a client asked to carry into a list the server will hand over. |
| `Arena.SlotsPerPlayer()` | How many weapons one player may carry, guns and blades together. 0 is no limit. |
| `Arena.ResolveWeaponEntry(weapon, ammoType, ammo)` | One weapon of a loadout, built -- policy-free, so the gun-game ladder can use it without being judged as a player request. |
| `Arena.ResolveLoadout(request)` | Validates a whole loadout request and returns the concrete thing to hand a player -- real GTA weapon names and real ammo counts, nothing the caller supplied passed through untouched. |
| `Arena.BoundaryOf(arena)` | The arena's boundary block when it is switched on -- the one reading of `enabled`. |
| `Arena.IsEliminated(row)` | Whether this player row is out of the round for good -- the one copy of that rule. |
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
| `Arena.PickRespawn(arenaKey, teamKey, avoid, rng, factor, prefer)` | Where to put a player who has just lost a life -- clear of `avoid`, and near `prefer` where it can be. |
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
| `Arena.ScheduleSpans()` | The opening-hours windows as sorted, disjoint spans of minutes; empty means always open. |
| `Arena.ScheduleStatus(hour, minute)` | Whether the arena is open at that time, and when it next opens or shuts. |
| `Arena.ClockText(minutes)` | Minutes since midnight as `HH:MM` -- the one place that formatting lives. |
| `Arena.ScheduleLine()` | The whole schedule on one line, or nil when the arena keeps no hours. |
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

#### `server/util.lua` — 23 functions

| Function | What it does |
|---|---|
| `ArenaLog(fmt, ...)` | Console line an operator will always see. |
| `ArenaDebug(fmt, ...)` | The chatty half. |
| `ArenaNotify(src, description, notifyType)` | One player-visible message, handed to client/ui.lua to place. |
| `ArenaToast(src, message, notifyType)` | A message that shows even while the arena panel is open, for the moments a closing panel would swallow the only thing the player needed to read. |
| `ArenaToastKey(src, localeKey, notifyType, ...)` | The same, from a locale key. |
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
| `ArenaHoursNow()` | The hour and minute the schedule is judged against -- the server's own clock, plus `offsetHours`. |
| `ArenaSetHoursOverride(mode)` | An admin's standing decision about the doors: `'open'`, `'shut'`, or anything else to follow the schedule. In memory, so a restart gives the clock its say back. |
| `ArenaHoursOverride()` | That decision, or nil where there is none. |
| `ArenaHoursOpen()` | Whether the doors are open right now. Fails OPEN on every path that cannot produce a schedule. |
| `ArenaHoursSnapshot()` | The opening-hours block the panel, the NPC and the marker are all drawn from. |
| `ArenaHoursState()` | The same facts kept apart, for `/arenahours`. |
| `ArenaDbReady(subject)` | Whether a query can be sent right now: `Config.Database.enabled` on and oxmysql started. Says so once per outage, per subject, and re-arms when the database comes back. |
| `ArenaDb(subject, sql, params, cb)` | Sends one query. Never lets a database failure take the round down, and always calls `cb` — with nil on every path that did not reach oxmysql. |

#### `server/dispatch.lua` — 13 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.Set(src, matchId)` | Marks a player as being in `matchId`. |
| `ArenaDispatch.Clear(src)` | Clears the flag. |
| `ArenaDispatch.ClearDownState(src)` | Puts the medical script's down flags back down, at the death rather than at the revive. |
| `ArenaDispatch.HoldDownState()` | One pass: the flags put back down for everybody currently in a match. |
| `ArenaDispatch.Revive(src)` | Tells whatever handles death on this server that a player is alive again. |
| `ArenaDispatch.IsPlayerInArena(src)` | Whether the server has this player flagged as being in a match. |
| `ArenaDispatch.GetPlayerMatchId(src)` | The match a flagged player is in, or nil. |
| `ArenaDispatch.GetArenaPlayers()` | Every player currently in a match, as a server-id -> match-id map. |
| `ArenaDispatch.GetBucket(matchId)` | The instance a match is fought in, allocating and configuring one the first time it is asked for. |
| `ArenaDispatch.EnterBucket(src, matchId)` | Moves a player into their match's instance, remembering what they were in beforehand. |
| `ArenaDispatch.ExitBucket(src)` | Puts a player back in exactly the bucket EnterBucket found them in, and hands the match's number back once the last person has left it. |
| `ArenaDispatch.ReleaseBucket(matchId)` | Gives a match's bucket number back to the pool. |
| `ArenaDispatch.IsolationState()` | What isolation is ACTUALLY doing right now, for the startup report and for /arenaisolation. |

#### `server/ammo.lua` — 17 functions

| Function | What it does |
|---|---|
| `ArenaAmmo.IsEnabled()` | Whether ammunition ITEMS are being handed out. |
| `ArenaAmmo.SwapWeapon(src, matchId, removeWeapon, entry, alsoClear)` | Swaps one issued tier weapon for another, for a gun-game promotion or demotion. |
| `ArenaAmmo.Refresh(src, matchId, loadout)` | Puts a respawning fighter back on a full magazine, full rounds and their picked supplies -- or takes the weapon away, where `allowWeaponWithoutAmmoItem` is off and its rounds could not be issued. |
| `ArenaAmmo.GrantRounds(src, matchId, item, count)` | A flat grant of ammunition onto the arena's ledger, for a kill reward. Hands over nothing where `Config.Loadouts.ammoItems.enabled` is off, like every other issue path. |
| `ArenaAmmo.GrantSupply(src, matchId, item, count)` | Hands one player one supply mid-round and puts it on the arena's books. |
| `ArenaAmmo.Issue(src, matchId, loadout)` | Puts the player's own kit away, then gives them what the loadout says. |
| `ArenaAmmo.Reclaim(src, reasonKey)` | Destroys the arena kit and hands the player's own inventory back. |
| `ArenaAmmo.Clear(matchId)` | Drops a match's record. |
| `ArenaAmmo.HeldFor(src)` | Everything the arena is holding for one player, read out of their stash. |
| `ArenaAmmo.ReturnLeftovers(src)` | Hands back anything of this player's still sitting in their arena stash. |
| `ArenaAmmo.SweepReturns()` | One pass over everybody on the server: outstanding stashes handed back, and any arena kit that left with a character taken off them. |
| `ArenaAmmo.LoadOwedKit()` | Reads the outstanding-kit slate back off the database, merging rather than replacing — weapon rows de-duplicate on serial, and a stack keeps whichever total is higher, so a debt incurred before the database came up is not forgiven. Does nothing with `Config.Database.enabled` off, and retries from the sweep until it lands. |
| `ArenaAmmo.Owed()` | How many characters this resource still owes belongings to — the stash debt, not the kit debt. |
| `ArenaAmmo.OwedKitIsSaved()` | Whether the slate is being written somewhere that survives a restart — measured from a query that actually landed, not inferred from the config. |
| `ArenaAmmo.OwedKit()` | Every arena weapon and item stack that left with a character and has not come back, one row per character. |
| `ArenaAmmo.AllStashes(cb, scanned)` | Every arena stash this server has ever made, whether or not this run remembers it. |
| `ArenaAmmo.QueueReturn(citizenid, stash)` | Puts one stash on the sweep's list, so an offline owner is handed it when next seen. |

#### `server/stats.lua` — 5 functions

| Function | What it does |
|---|---|
| `ArenaStats.Record(entry)` | Folds one player's finished match into the totals. |
| `ArenaStats.RecordMatch(match)` | Records every player of a finished match in one call. |
| `ArenaStats.GetLeaderboard(cb)` | Hands the top rows to `cb`. |
| `ArenaStats.Flush()` | Writes everything queued and empties the queue. |
| `ArenaStats.EnsureSchema()` | Creates the table if it is not there. |

#### `server/betting.lua` — 31 functions

| Function | What it does |
|---|---|
| `ArenaBetting.Accounts()` | The accounts a player may be asked to choose between, in the operator's own order. |
| `ArenaBetting.Wallet(src)` | What one player holds in each of them, for the panel's own display. |
| `ArenaBetting.BetsAreOpen(match)` | Whether the book is still taking side-bets on this match, for a WATCHER. |
| `ArenaBetting.FighterBetsAreOpen(match)` | The same question for somebody fighting in it, which shuts the moment the round goes live. |
| `ArenaBetting.SecondsUntilBetsClose(match)` | Seconds until the book shuts on a live round, or nil when there is no window to wait on. |
| `ArenaBetting.IsRefundReason(reason)` | Whether a payout line is a stake coming back rather than money won. |
| `ArenaBetting.IsEnabled()` | Whether betting is switched on at all. |
| `ArenaBetting.StakeOf(matchId, src)` | What one player has staked on one match and not yet had back. |
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
| `ArenaBetting.MatchesBackedBy(src)` | Every match this player currently has an unsettled side-bet on, so the panel can refuse a Join the server would refuse. |
| `ArenaBetting.HasSpectatorBet(matchId, src)` | Whether this player holds any side-bet on this match, settled or not. |
| `ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)` | Takes a spectator's side-bet on a team or a fighter. |
| `ArenaBetting.CountSideBets(matchId)` | How many unsettled side-bets are riding on a match, so a mode change can be refused rather than voiding the whole book. |
| `ArenaBetting.MarkWalkedOut(matchId, src)` | Marks this player's unsettled bets as placed by somebody who then left, so the dead-pick refund never hands them back, and trims a fighter's stake to what a non-fighter may hold. |
| `ArenaBetting.ReturnBetsOn(matchId, pick)` | Hands back every unsettled side-bet on one pick, because that pick can no longer win. |
| `ArenaBetting.SettleSpectatorBets(matchId, winningPick)` | Settles every side-bet on a match. |
| `ArenaBetting.PayOutstanding(src)` | Pays one character everything this resource owes them from a refund that could not be delivered. |
| `ArenaBetting.SweepUnpaid()` | Pays everybody on the server whatever they are still owed. |
| `ArenaBetting.Outstanding()` | How much this resource still owes, across how many characters. |
| `ArenaBetting.Clear(matchId)` | Drops a match's money state. |

#### `server/lobby.lua` — 25 functions

| Function | What it does |
|---|---|
| `ArenaLobby.Get(matchId)` | One match by id, or nil. |
| `ArenaLobby.GetByPlayer(src)` | The match a player is attached to, or nil. |
| `ArenaLobby.All()` | Oldest first, id breaking the tie, so two reads of an unchanged registry can never render the match list in a different order. |
| `ArenaLobby.PlayerCount(match)` | How many players a match has seated. |
| `ArenaLobby.PlayerArray(match)` | The roster as an ARRAY, in join order -- the shape every Arena.* rule takes, and the order a spawn index is drawn from. |
| `ArenaLobby.NoteEditRefused(src)` | Records that one player asked for an edit the server would not make, so the panel re-seeds the form. |
| `ArenaLobby.ForgetEditRefusals(src)` | Drops that count on the way out, so a recycled server id inherits nothing. |
| `ArenaLobby.PushState(src)` | Sends one player the snapshot as it stands right now -- the undo for a request the server refused. |
| `ArenaLobby.BuildState(src)` | The whole snapshot one player is allowed to see: matches, their own row, the leaderboard and their wallet. |
| `ArenaLobby.Broadcast()` | Pushes the snapshot to everyone who can see it and nobody who cannot. |
| `ArenaLobby.MarkPanelOpen(src)` | Records that this player has the panel up, so pushes reach them. |
| `ArenaLobby.MarkPanelClosed(src)` | Records that this player has closed the panel. |
| `ArenaLobby.Create(src, arenaKey, modeKey, entryFee, lives, radar, account)` | Opens a lobby and puts its host in it. |
| `ArenaLobby.Join(src, matchId, teamKey, account)` | Seats a player in an open lobby, taking their entry fee. |
| `ArenaLobby.MayLeave(src, dropped)` | Whether a player may take themselves out of the match they are in -- refused while they hold a side-bet on a lobby or a countdown, never on a disconnect. |
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

#### `server/match.lua` — 8 functions

| Function | What it does |
|---|---|
| `ArenaMatch.Begin(matchId, requestedBy)` | Validates a lobby and runs the countdown players may still back out of. |
| `ArenaMatch.Start(matchId)` | Teleports everybody in, hands out the loadouts, and starts the frozen countdown that ends with weapons live. |
| `ArenaMatch.OnDeath(src, killerSrc)` | One player died. |
| `ArenaMatch.End(matchId, reasonKey, winners)` | Ends a round that was actually fought: decides the winners, settles the money, records it, and sends everybody home with a result. |
| `ArenaMatch.Abort(matchId, reasonKey)` | The refund-everything path: a resource stop, an admin force-stop, a lobby that emptied out, a round that could not start. |
| `ArenaMatch.RemovePlayer(src, reasonKey)` | One player out, mid-round: they left, they were dropped, or an admin pulled them. |
| `ArenaMatch.CloseWaitingLobbies(reasonKey)` | Shuts every lobby still waiting to start -- including one counting down that nobody has been placed in -- and hands back every stake. A round anybody is standing in is left to finish. Run when a schedule window closes and when an admin closes the arena. Answers how many it tried to close. |
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

#### `client/dispatch.lua` — 6 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.IsInArena()` | Whether this player is currently in an arena match. |
| `ArenaDispatch.MatchId()` | The match this client believes it is in, or nil. |
| `ArenaDispatch.Enter(matchId)` | Calls the operator's own mute exports and latches the match id. No game setting is touched. |
| `ArenaDispatch.Exit()` | Undoes Enter(), exactly. Safe when nothing is active. |
| `ArenaDispatch.ClearDeadState(ped)` | Puts an arena casualty back on their feet in the same instant they went down, held frozen, invisible and untouchable until the server says what happens next. |
| `ArenaDispatch.ReleaseDeadState(ped)` | Undoes ClearDeadState's holding pattern. |

#### `client/main.lua` — 6 functions

| Function | What it does |
|---|---|
| `ArenaState.Get()` | The whole last-known snapshot, or nil before the first push. |
| `ArenaState.Set(newState)` | Replaces the cache. |
| `ArenaState.MatchId()` | The match this player belongs to, lobby or live, or nil. |
| `ArenaState.IsInMatch()` | Whether this player is attached to a match, lobby or live. |
| `ArenaState.Schedule()` | The opening-hours block the server last sent; always a table. |
| `ArenaState.DoorsShut()` | True only when the server has explicitly said the arena is shut. |

#### `client/match.lua` — 4 functions

| Function | What it does |
|---|---|
| `ArenaMatch.SetKeepOut(zones)` | Sets the arenas this client is fenced out of because a round it is not in is being fought there. |
| `ArenaMatch.SetRadar(on)` | Set from `enterArena` -- never from the panel, which no longer has a control that reaches this side. |
| `ArenaMatch.EnsureSpectatorScenery(arenaKey, factor)` | Builds the arena's props for somebody watching it, who is never sent `enterArena` and so never built them. Refuses to touch a fighter's own scenery. |
| `ArenaMatch.DropSpectatorScenery()` | Takes down only scenery EnsureSpectatorScenery put up. |

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

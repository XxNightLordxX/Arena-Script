# Crimson Arena — Feature and Function Reference

> **A SNAPSHOT, AND IT MAY DRIFT.** This file was kept honest by a test —
> `tests/checklist_spec.lua` compared every table below against the real
> files and failed the build when they disagreed. That test has been removed
> with the rest of the suite for release, so from this point on nothing
> checks this document. It was accurate on the day it was written; treat it
> as a map rather than as the territory, and trust the code where the two
> disagree.


*Everything this resource does, and every function it does it with.*

`README.md` explains how to run the arena and put it on a live server. This file
is the inventory: what the resource does,
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
- **A countdown you are held for** -- leaving is refused for its whole length,
  so one player cannot call the round off for everybody -- then a frozen
  countdown once everybody is in the arena and armed.
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

- **96 weapons catalogued and all 96 enabled** — the whole `heavy` category
  included (13 entries: the RPG, five launchers, the minigun, both railguns,
  the Unholy Hellbringer, the Widowmaker and the flamethrower), so explosives
  are pickable and explosive damage is not refused between teammates whatever
  `Config.Teams.friendlyFire` says. Filed in categories. A player carries
  `Config.Loadouts.slots` of them — guns and melee against one count, so the mix
  is theirs.
- **The host or the player picks**, per `Config.Loadouts.chooser`.
- **You pick an amount of ammunition, not a type.** The correct ammo item for that
  weapon is worked out and handed over automatically: one magazine loaded in the
  gun, the rest as items, totalling exactly what was picked.
- **Full health and a full plate on every life, by rule** — not a config key, not a field a client can send.
- **Choosable spare kit**: extra armour plates and bandages, per-item maximums
  (25 and 30 as shipped), issued as real items and reclaimed against what the
  player still holds. There is *also* a ceiling across all supplies together,
  `Config.Loadouts.supplies.totalItems` — but **it ships at 0, which means no
  ceiling**, so on the shipped config the per-item maximums are the only
  limit and nothing is squeezed by a total.
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
  claiming isolation for the rest of the run. **Tools → Instancing** prints the
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
| Modes | **Free For All** (`ffa`, the default), **Team Deathmatch** (`tdm`), **Gun Game** (`gungame`) | — |
| Teams | **Crimson** (`crimson`), **Ash** (`ash`) | Bone (`bone`), Ember (`ember`) |
| Weapons | **96 — all of them**, the whole `heavy` category included | *(none)* |

Other shipped defaults worth knowing: betting **on** (entry fees, spectator bets
and fighter bets all on), the database **off** (so the board, and the record of what
players still owe the arena, both cover the current server run only), webhooks **off**, `Config.Debug` **on**, loadouts chosen by
the **host**, ammunition items **on**, the inventory door **on**, minimum 2 players,
no maximum, no cap on concurrent matches, and `last_standing` as the win condition.

---

## Commands

All five are gated on `Config.Permissions.adminGroups`; the server console
always qualifies. **An empty `adminGroups` means nobody may run any of them** —
job lists elsewhere in `Config.Permissions` read empty as "everyone", and this
one deliberately does not.

| Command | What it does |
|---|---|
| `/arenaadmin` | Opens the admin tablet, and takes no arguments — everything is a button on the screen: force-stop and **Stop every match** on **Matches**; hand-backs and **Clear the hold** on **Stashes**, under the item list, so a hold is settled by somebody who has READ the contents; the doors, the revive, and under **Tools** the instancing, opening-hours, police/EMS, attachment and held-back-stash readings, **Money owed**, and the **Medical test**. At a server console — which cannot be shown a screen — it lists what is running and nothing else. |
| `/arenaconsole` | Prints every one of those readings to the server console in one pass, for the place a screen cannot go. No arguments. The **Medical test** is deliberately not in it: that one revives a named player rather than reading the server, so it stays a button with a box to put the server id in. An in-game admin who runs it gets one line saying where it went. |

**Those are the only two.** `/arenadispatch`, `/arenarevive`, `/arenaattachments`, `/arenaisolation` and `/arenaunjam` were commands of their own and are not any more: every reading they printed is a button on the tablet under **Tools**, and `/arenaconsole` prints all of them at a console. The revive became the **Medical test** button, which takes a server id; clearing a jam became **Clear the hold**, on the stash whose contents it is about. `tests/commands_spec.lua` fails if a third command is ever registered without being made discoverable.

### Exports — what other resources may ask

`server/exports.lua` holds the whole public surface, in one file, so it can be read in one
sitting. Call them as `exports['Crimson-Arena']:Name(...)` on the server.

| Export | Answers | Quiet answer if the arena cannot tell |
|---|---|---|
| `IsPlayerInArena(src)` | whether that player is in a match right now | `false` |
| `ShouldSuppressAlert(src)` | whether a police or EMS alert for that player should be dropped — **true for a few seconds after a fighter leaves a match as well as while they are in one** | `false` |
| `GetPlayerMatchId(src)` | the match id, or nil | `nil` |
| `GetArenaPlayers()` | every player in a match, as `{ [src] = matchId }` | `{}` |
| `IsArenaOpen()` | whether the doors are open, schedule and admin override both | `false` |
| `GetMatches()` | one flat row per match: `id`, `label`, `arenaKey`, `modeKey`, `state`, `players`, `pot` | `{}` |
| `GetPot(matchId)` | what is staked on one match, entry fees and side bets together | `0` |
| `GetOwedKit([citizenid])` | the whole owed-kit slate, or one character's row — `nil` for a character nobody is owed anything for | `{}`, or `nil` when asked about one |
| `GetOwedMoney()` | what the arena still owes players, as one total | `0` |

`client/exports.lua` is the same file for the other realm: `IsInArena()` and
`GetArenaMatchId()`, under the same rules. An export registered in a server script is
callable only from a server script, so the surface is two files because there are two
realms — not because it is split.

**`ShouldSuppressAlert` is the one a dispatch script should call, not `IsPlayerInArena`.**
An alert is raised from a death, and the arena's flag comes down the instant the round
resolves — routinely *before* the other script gets round to filing the call for the body
that just fell. `IsPlayerInArena` answers that honestly with `false` and the page goes out
anyway. `ShouldSuppressAlert` stays `true` for a few seconds afterwards — the narrow window,
not the retract sweep's wide one, because this answer suppresses an alert *before* it is ever
filed and a mistake leaves no trace to notice. It is also the only export here whose fallback
is the *loud* answer: if the arena cannot tell, the alert is raised. A spurious alert during a
round is an annoyance; a swallowed one for a city death is not. `DISPATCH-ALERTS.md` covers
how sc-dispatch asks this resource instead — on the player's own client, before an alert is
raised at all.

**Every one of these is a reading.** Nothing stops a match, pays anybody, issues kit or
clears a hold, and that is a line rather than a gap. An export is callable by any resource
on the box with no ACE check in front of it — the tablet's gates do not apply and cannot be
made to — so an action export would be an unauthenticated way into the arena's money and its
rounds.

**Nothing internal is handed out.** `ArenaLobby.All()` returns the *live* match tables, so
every table these exports answer with is built per call from scalars. `tests/exports_spec.lua`
writes to what came back and checks the arena's own copy is untouched, including nested
lists.

**Nothing throws into a caller.** Each body runs inside `pcall` and answers with the quiet
value above if the arena is mid-restart or a module has not loaded. A resource asking the
arena a question cannot die because the arena is having a bad minute.

**The shape is a promise.** Once another resource reads a field, renaming it breaks their
server silently. Add a field freely; do not rename or repurpose one. The spec pins the list
of names and fails if one is added, removed or renamed without saying so here.

There are two other ways in, both documented in `config.lua` under `Config.Dispatch.custom`:
the `crimson_arena:dispatch:enter` / `:exit` server events, and the replicated
`crimsonArena` state bag.

**No player-facing slash command exists.** The panel opens from the lobby ped or
the ground marker, whichever `Config.Lobby.interaction` names, and there is no
setting that adds a second way in.

---

## Exports for other resources

> **The name in front of the colon is your FOLDER name, not a fixed string.**
> FiveM names a resource after the directory it sits in, so these read
> `exports['Crimson-Arena']` because that is what this folder is called. Rename
> the folder and every line below changes with it -- and an export that names a
> resource which does not exist does not raise anything, it just quietly does
> nothing, which is the worst way for an integration to fail.
>
> **If you would rather not care, use the state bag at the bottom of this
> section.** It is keyed on `Config.Dispatch.custom.stateBagKey`, not on the
> folder, so it keeps working whatever anybody calls this resource.

**Server**

| Export | Returns |
|---|---|
| `exports['Crimson-Arena']:IsPlayerInArena(src)` | Whether that player is in a match right now. |
| `exports['Crimson-Arena']:ShouldSuppressAlert(src)` | Whether a dispatch or medical alert for them should be dropped. Covers the few seconds after a fighter leaves a match, which `IsPlayerInArena` does not. |
| `exports['Crimson-Arena']:GetPlayerMatchId(src)` | The match id they are in, or nil. |
| `exports['Crimson-Arena']:GetArenaPlayers()` | Every player in a match, as a `src -> matchId` map. A copy. |

**Client**

| Export | Returns |
|---|---|
| `exports['Crimson-Arena']:IsInArena()` | Whether this player is in a match. |
| `exports['Crimson-Arena']:GetArenaMatchId()` | The match id, or nil. |

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
`placeSpectatorBet`, `outlineReason` — all prefixed `crimson_arena:server:`.

And six more the admin tablet sends, same prefix:

`adminState`, `adminStop`, `adminReturn`, `adminUnjam`, `adminHours`, `adminRevive`.

Every one of those six opens with
`if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end`,
which is where the gate has to be: **a `RegisterNetEvent` listener exists for
every connected client whatever the panel draws for them**, so hiding the
tablet button is not a permission check. The other seventeen are open to any
player by design and are gated on state instead — you cannot leave a match you
are not in.

**Callback:** `crimson_arena:server:getState` — the panel's opening snapshot.

**Server → client**, all prefixed `crimson_arena:client:`:

`state`, `enterArena`, `exitArena`, `matchLive`, `matchHud`, `countdown`,
`results`, `eliminated`, `respawn`, `notify`, `closePanel`, `holdVitals`,
`openAdmin`, `adminState`.

---

## Configuration map

`config.lua` is one file, heavily commented, and its own header carries a
line-number map that is regenerated whenever the file changes.

| Block | What it governs |
|---|---|
| `Config.ResourceLabel`, `Config.Debug`, `Config.NotifyTitle` | Naming and the debug channel. |
| `Config.Lobby` | The lobby ped, the ground marker, the blip, how players interact with it, and where they are returned to. |
| `Config.Schedule` | Opening hours. Ships **on**, with four windows, on the server's own real clock rather than the city's — outside them nobody may create a match and nobody may join one. `offsetHours` shifts them if the box does not run in your players' timezone. |
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
| `server/dispatch.lua` | server | The in-arena flag, routing-bucket isolation, the revive, and the instancing and medical-test readings the tablet draws. |
| `server/ammo.lua` | server | The inventory door, every weapon and ammunition item issued and reclaimed, the slate of what players still owe the arena, and the held-back-stash and attachment readings the tablet draws. |
| `server/stats.lua` | server | The leaderboard, in memory and in MySQL. |
| `server/betting.lua` | server | Escrow, side bets, refunds and payouts. |
| `server/lobby.lua` | server | The match registry, joining, leaving, readiness and the state snapshot. |
| `server/match.lua` | server | The round itself: start, deaths, respawns, the end, and the instancing sweep. |
| `server/main.lua` | server | Every client entry point, its validation and its rate limit. |
| `server/exports.lua` | server | The public surface: everything another resource on this server may ask the arena. Loaded LAST, so every module it names exists. Readings only — see below. |
| `client/ui.lua` | client | The NUI bridge. |
| `client/dispatch.lua` | client | Client-side suppression, and holding an arena casualty out of every death poll. |
| `client/main.lua` | client | The lobby ped, the marker, the blip and the cached state. |
| `client/match.lua` | client | Being in a round: the loadout, the boundary, the props, the blips and outlines, the HUD. |
| `client/spectate.lua` | client | The spectate camera and its target list. |
| `client/exports.lua` | client | The public surface on the client: `IsInArena()` and `GetArenaMatchId()`. Loaded LAST for the same reason `server/exports.lua` is. |
| `html/` | — | The panel. |
| `locales/` | — | Every player-visible string. |
| `sql/install.sql` | — | All four tables — the leaderboard, the outstanding-kit slate, the unpaid-winnings ledger and the jammed-stash record — for operators who import by hand. Needs `DELETE` granted as well as `SELECT`/`INSERT`/`UPDATE`. |
| `sql/uninstall.sql` | — | Drops all four. Dropping the slate forgives every debt it holds, and dropping the unpaid ledger forgives every winning still owed. |

---

## Function reference

Every function each file exposes, in the order it is defined. Local helpers are not
listed; the source documents them where they are.

#### `shared/arena.lua` — 107 functions

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
| `Arena.WeaponByHash(hash)` | The catalogue weapon a death's cause-of-death hash names, or nil. The dying client reads `GetPedCauseOfDeath` and reports the hash; there is no server native for it and `weaponDamageEvent` does not carry it, so this is the only way the server can name what killed somebody. Indexes BOTH signs of every hash -- `GetHashKey` answers signed and `GetPedCauseOfDeath` unsigned, so a map built from one answers nothing to the other. nil is an ordinary answer: a fall, a vehicle, fire and every switched-off weapon all land there. |
| `Arena.IsUnarmedHash(hash)` | Whether a cause-of-death hash is WEAPON_UNARMED -- fists. They can never be in the weapon catalogue, so `Arena.WeaponByHash` answers nil for them exactly as it does for a fall, and gun game's melee-only demotion rule read that nil as "not melee" and handed a punched fighter their tier back. A punch is melee and reports a hash of its own, so it is asked for by name. Checks BOTH signs of `0xA2719263`, whose top bit is set. The constant is written out rather than hashed because `GetHashKey` is absent in some realms this file loads in; `arena_spec` pins it against a real joaat. |
| `Arena.GetWeaponByKey(key)` | The one weapon with this key, or nil. |
| `Arena.GetEnabledTeams()` | Enabled teams, sorted by their `order` then key so every client renders the picker in the same sequence. |
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
| `Arena.AttachmentKinds()` | Which kinds of attachment the operator wants fitted, in order. Empty when the feature is switched off. |
| `Arena.AttachmentsAreChosen()` | Whether the PLAYER picks their own attachments, or the server fits them. False also when attachments are switched off entirely. |
| `Arena.AttachmentOptionsFor(weaponName)` | What this weapon may be offered in the picker -- key and label per kind, resolved through the same table the server fits from, so a chip can never offer what the server would refuse. |
| `Arena.AttachmentsFor(weaponName, chosen)` | The components one weapon is fitted with. `chosen` is a list of KIND keys and never component names, which is what stops a client fitting itself anything it likes; nil means whatever this server fits by default. |
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
| `Arena.BetPayoutMode(kind)` | Who funds a winning bet of this kind: 'pool' (the losers) or 'odds' (the operator). The ONE answer -- the bet is stamped with it and the panel is told it, so the two cannot drift. Returns 'pool' whatever betPayout says unless `Config.Betting.allowServerFundedPayouts` is true, because an odds bet is the operator's money and the bettor can be the person deciding the result. |
| `Arena.ServerFundedPayoutsRefused()` | Whether the operator has written 'odds' without opening that gate, so ReportConfigProblems can say why nothing is being paid at it. |
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
| `Arena.HoursOffset(value)` | The hours `Config.Schedule.offsetHours` really shifts the server clock by -- 0 for anything unusable or past 14 either way. Returns a SECOND value: whether the configured one is that number, which is what `ValidateConfig` complains about and what `/arenahours` and the boot log print as IGNORED. The one reader of the -14..14 rule. |
| `Arena.ScheduleSpans()` | The opening-hours windows as sorted, disjoint spans of minutes; empty means always open. Returns a SECOND value: how many configured windows survived the validity test. Not `#spans` — spans are merged, so two touching windows are two windows and one span, and a wrap-around is one window and two spans. `/arenahours` reports the count. |
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

#### `server/util.lua` — 24 functions

| Function | What it does |
|---|---|
| `ArenaLog(fmt, ...)` | Console line an operator will always see. |
| `ArenaDebug(fmt, ...)` | The chatty half. |
| `ArenaNotify(src, description, notifyType)` | One player-visible message, handed to client/ui.lua to place. |
| `ArenaToast(src, message, notifyType)` | A message that shows even while the arena panel is open, for the moments a closing panel would swallow the only thing the player needed to read. |
| `ArenaToastKey(src, localeKey, notifyType, ...)` | The same, from a locale key. |
| `ArenaNotifyKey(src, localeKey, notifyType, ...)` | The form almost every caller wants: Arena.* hands back locale KEYS, not sentences, and they go straight through here. |
| `ArenaGetPlayer(src)` | The qbx_core player object for a server id, or nil. |
| `ArenaCutText(value, limit)` | A player-supplied string cut to fit a database column without splitting a multi-byte character in half. `string.sub` counts bytes and the columns count characters, and a cut landing mid-character hands MySQL invalid UTF-8, which it refuses the whole row for. |
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
| `ArenaHoursState()` | The same facts kept apart, for the opening-hours reading. |
| `ArenaDbReady(subject)` | Whether a query can be sent right now: `Config.Database.enabled` on and oxmysql started. Says so once per outage, per subject, and re-arms when the database comes back. |
| `ArenaDb(subject, sql, params, cb)` | Sends one query. Never lets a database failure take the round down, and always calls `cb` — with nil on every path that did not reach oxmysql. |

#### `server/dispatch.lua` — 20 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.Set(src, matchId, isFighter)` | Marks a player as being in `matchId`. `isFighter` is true only for somebody PLACED in the round, and decides whether leaving earns a suppression window. |
| `ArenaDispatch.Clear(src)` | Clears the flag. |
| `ArenaDispatch.ClearDownState(src)` | Puts the medical script's down flags back down, at the death rather than at the revive. |
| `ArenaDispatch.HoldDownState()` | One pass: the flags put back down for everybody currently in a match. |
| `ArenaDispatch.Revive(src)` | Tells whatever handles death on this server that a player is alive again. |
| `ArenaDispatch.ReviveReport(target)` | Runs the end-of-match revive against one player and says what happened, as lines. The one admin action that deliberately reaches somebody who is NOT in a match: it exists so an operator can watch their medical script answer the arena's revive without first putting a player through a round. Drawn by the admin tablet under **Tools → Medical test**, and deliberately NOT in `/arenaconsole`: that command takes no arguments and cannot ask which player, and reviving whoever typed it -- or nobody, at a console -- is not a diagnostic. |
| `ArenaDispatch.IsPlayerInArena(src)` | Whether the server has this player flagged as being in a match. |
| `ArenaDispatch.GetPlayerMatchId(src)` | The match a flagged player is in, or nil. |
| `ArenaDispatch.GetArenaPlayers()` | Every player currently in a match, as a server-id -> match-id map. |
| `ArenaDispatch.ShouldSuppressAlert(src)` | Whether an alert for this player should be dropped: flagged, or a fighter who was flagged within the last few seconds. |
| `ArenaDispatch.ClearBucket(bucket, matchId)` | Deletes what a finished round left standing in its own instance -- scoped by routing bucket, never by coordinates, and refused outright for a bucket anybody is still in. |
| `ArenaDispatch.GetBucket(matchId)` | The instance a match is fought in, allocating and configuring one the first time it is asked for. |
| `ArenaDispatch.EnterBucket(src, matchId)` | Moves a player into their match's instance, remembering what they were in beforehand. |
| `ArenaDispatch.ExitBucket(src)` | Puts a player back in exactly the bucket EnterBucket found them in, and hands the match's number back once the last person has left it. |
| `ArenaDispatch.ReleaseBucket(matchId)` | Gives a match's bucket number back to the pool, empty. |
| `ArenaDispatch.IsolationState()` | What isolation is ACTUALLY doing right now, for the startup report and for **Tools → Instancing**. |
| `ArenaDispatch.IsolationReport()` | The routing-bucket isolation of every live match, as lines. Drawn by the admin tablet under **Tools → Instancing**, and printed by `/arenaconsole` at a console. |
| `ArenaDispatch.CompatReport()` | The police/EMS compat report shared/compat/dispatch.lua builds, as lines, plus two lines of its own: what the down-state edge listener is doing, and what sc-dispatch's own arena integration is doing (its switch, and whether a renamed `stateBagKey` has broken the half that covers spectators). Drawn by the admin tablet under **Tools → Police & EMS**, and printed by `/arenaconsole` at a console. |
| `ArenaDispatch.WithdrawFiledCall(data)` | Withdraws one dispatch call by the id the dispatch script itself announced, the instant it is filed. sc-dispatch broadcasts every alert on a plain server event before it writes a row; this reads that, checks the call is about somebody in a match, and clears the exact id — no guessing at id shapes, and it covers routes this resource has never heard of. |
| `ArenaDispatch.RetractCallsFor(src)` | Withdraws every dispatch call this player is the subject of, by their server id, so an alert raised by a path the arena never saw does not sit on the responders' screens after the revive. |

#### `server/ammo.lua` — 28 functions

| Function | What it does |
|---|---|
| `ArenaAmmo.IsEnabled()` | Whether ammunition ITEMS are being handed out. |
| `ArenaAmmo.SwapWeapon(src, matchId, removeWeapon, entry, alsoClear)` | Swaps one issued tier weapon for another, for a gun-game promotion or demotion. |
| `ArenaAmmo.Refresh(src, matchId, loadout)` | Puts a respawning fighter back on a full magazine, full rounds and their picked supplies -- or takes the weapon away, where `allowWeaponWithoutAmmoItem` is off and its rounds could not be issued. |
| `ArenaAmmo.GrantRounds(src, matchId, item, count)` | A flat grant of ammunition onto the arena's ledger, for a kill reward. Hands over nothing where `Config.Loadouts.ammoItems.enabled` is off, like every other issue path. |
| `ArenaAmmo.GrantSupply(src, matchId, item, count)` | Hands one player one supply mid-round and puts it on the arena's books. |
| `markWeaponOut(record)` | Writes the row that says this exact weapon is OUT, the moment it is handed over, so a crash leaves evidence. Forward-declared near `giveWeapon`; assigned here, below the SQL it needs. |
| `strikeWeaponOff(record)` | Removes that row when the weapon actually comes back. |
| `ArenaAmmo.Issue(src, matchId, loadout)` | Puts the player's own kit away, then gives them what the loadout says. |
| `ArenaAmmo.Reclaim(src, reasonKey)` | Destroys the arena kit and hands the player's own inventory back. |
| `ArenaAmmo.Clear(matchId)` | Drops a match's record. |
| `ArenaAmmo.JammedStashes()` | Every stash the door has stopped touching, because something is in it the arena cannot account for. |
| `ArenaAmmo.IsJammed(stash)` | Whether one stash is held back, and whether that answer has been read back from the database yet. The second return is what stops the admin tablet drawing an unread list as fact and offering a hand-back the door is certain to refuse. |
| `ArenaAmmo.JamReport()` | What the tablet draws under **Tools → Held-back stashes**, as lines. Read-only: it names what is held back and points at the Stashes tab, and clears nothing itself. |
| `ArenaAmmo.Unjam(stash)` | Lets the door use one of those stashes again, once a human has settled it. The mechanism, not the judgement — go through `ClearHold`. Never automatic: an empty read is what ox_inventory says about an inventory it has not loaded, so only a person can say a jam is over. |
| `ArenaAmmo.ClearHold(stash, forced)` | The one gate every way of clearing a hold goes through — today that is the tablet's **Clear the hold** button, and anything added later asks it too. Refuses a stash that still holds rows, or one that cannot be read, unless the operator has said they have looked at it. |
| `ArenaAmmo.HeldFor(src)` | Everything the arena is holding for one player, read out of their stash. |
| `ArenaAmmo.ReturnLeftovers(src)` | Hands back anything of this player's still sitting in their arena stash. |
| `ArenaAmmo.SweepReturns()` | One pass over everybody on the server: outstanding stashes handed back, and any arena kit that left with a character taken off them. |
| `ArenaAmmo.LoadJams()` | Reads back the list of stashes the door is holding off, so a restart cannot hand out a duplicate a jam was parked to stop. Does nothing with `Config.Database.enabled` off, and retries from the sweep until it lands; the door holds every hand-back until it has. |
| `ArenaAmmo.LoadOwedKit()` | Reads the outstanding-kit slate back off the database, merging rather than replacing — weapon rows de-duplicate on serial, and a stack keeps whichever total is higher, so a debt incurred before the database came up is not forgiven. Does nothing with `Config.Database.enabled` off, and retries from the sweep until it lands. |
| `ArenaAmmo.Owed()` | How many characters this resource still owes belongings to — the stash debt, not the kit debt. |
| `ArenaAmmo.OwedKitIsSaved()` | Whether the slate is being written somewhere that survives a restart — measured from a query that actually landed, not inferred from the config. |
| `ArenaAmmo.OwedKit()` | Every arena weapon and item stack that left with a character and has not come back, one row per character. |
| `ArenaAmmo.AllStashes(cb, scanned)` | Every arena stash this server has ever made, whether or not this run remembers it. |
| `ArenaAmmo.QueueReturn(citizenid, stash)` | Puts one stash on the sweep's list, so an offline owner is handed it when next seen. |
| `ArenaAmmo.WeaponItemReport()` | Every WEAPON, AMMO and SUPPLY name this arena hands out, checked against this server's ox_inventory item list, as lines. Printed at start-up just before the attachment report. A name ox_inventory has no item for is REFUSED at the moment it is handed over, and the fighter gets nothing in its place -- the live symptom being "the host chose 4 weapons and all it had was the vests and bandages", because supplies are ordinary items a server usually does have. Asks only whether the name exists, NOT whether it is tagged a component the way `AttachmentReport` must. |
| `ArenaAmmo.AttachmentReport()` | Every attachment name the config can fit, checked against this server's ox_inventory item list, as lines. Printed at start, by `/arenaconsole`, and on the admin tablet under **Tools → Attachments**. A name ox_inventory has no item for, or has an item for that is not a component, is dropped rather than fitted, because handing it one leaves the weapon undrawable. |
| `ArenaAmmo.WithdrawMissingWeapons()` | Switches off every catalogue weapon whose ox_inventory item this server does not have, so a host cannot pick one that cannot be delivered, and returns the keys withdrawn. Runs at start-up straight after `WeaponItemReport`, which is the order that matters: the report walks the enabled catalogue, so withdrawing first would hide the very names an operator needs. Prevention rather than substitution -- the weapons a host picks are the ones their fighters get, instead of being armed with something nobody chose. Withdraws NOTHING where ox_inventory is absent or will not answer `Items()`, since emptying the catalogue of a healthy server is worse than the failure being prevented. Each withdrawal is marked so it keeps appearing in the report that explains it, and named on the console. `Config.Loadouts.withdrawMissingWeapons = false` keeps the old behaviour. |

#### `server/stats.lua` — 6 functions

| Function | What it does |
|---|---|
| `ArenaStats.Record(entry)` | Folds one player's finished match into the totals. |
| `ArenaStats.WouldRank(match)` | Whether this match would move anybody's ranking, for the one row ArenaLobby.Leave books itself. |
| `ArenaStats.RecordMatch(match)` | Records every player of a finished match in one call. |
| `ArenaStats.GetLeaderboard(cb)` | Hands the top rows to `cb`. |
| `ArenaStats.Flush()` | Writes everything queued and empties the queue. |
| `ArenaStats.EnsureSchema()` | Creates the table if it is not there. |

#### `server/betting.lua` — 37 functions

| Function | What it does |
|---|---|
| `ArenaBetting.Accounts()` | The accounts a player may be asked to choose between, in the operator's own order. |
| `ArenaBetting.Wallet(src)` | What one player holds in each of them, for the panel's own display. |
| `ArenaBetting.PendingUnpaidWrites()` | How many owed rows are queued but have not reached `crimson_arena_unpaid` yet. The Money owed report reads it so its durability line stops covering them over: the table being writable is not the same as every debt in the list having landed in it, and a restart forgets the ones that have not. |
| `ArenaBetting.UnpaidIsSaved()` | Whether the money the arena still owes players is being written somewhere that survives a restart. False with `Config.Database.enabled` off, which is the shipped default -- the debt still holds for this run, but a restart forgets it, and the deferred-refund line says so. |
| `ArenaBetting.BetsAreOpen(match)` | Whether the book is still taking side-bets on this match, for a WATCHER. |
| `ArenaBetting.FighterBetsAreOpen(match)` | The same question for somebody fighting in it, which shuts the moment the round goes live. |
| `ArenaBetting.SecondsUntilBetsClose(match)` | Seconds until the book shuts on a live round, or nil when there is no window to wait on. |
| `ArenaBetting.IsRefundReason(reason)` | Whether a payout line is a stake coming back rather than money won. |
| `ArenaBetting.IsEnabled()` | Whether betting is switched on at all. |
| `ArenaBetting.StakeOf(matchId, src)` | What one player has staked on one match and not yet had back. |
| `ArenaBetting.GetPot(matchId)` | What a match is holding right now. |
| `ArenaBetting.OthersStaked(matchId, exceptSrc)` | Whether anybody other than `exceptSrc` -- the host -- holds an unsettled entry stake on the match. The question the rules lock asks; `GetPot > 0` counted the host's own stake and locked every lobby against the only person in it. |
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
| `ArenaBetting.MatchesWalkedOutOf(src)` | Every round this player walked out of while it was being fought, so the panel stops offering them the watcher's grace on it. |
| `ArenaBetting.MatchesBackedBy(src)` | Every match this player currently has an unsettled side-bet on, so the panel can refuse a Join the server would refuse. |
| `ArenaBetting.HasSpectatorBet(matchId, src)` | Whether this player holds any side-bet on this match, settled or not. |
| `ArenaBetting.SideBetTotals(matchId)` | The same money broken down as pool -> pick -> amount, so the Bets tab can show whether anybody is backing the other side. Keyed by SETTLEMENT pool (see poolKeyFor): with `betPayout.sharedPool` off the two kinds are paid out of separate pools, and a flat book would credit a bettor with money they cannot win. Built with GetSideBetPool's filter, so within one pool the parts add up. |
| `ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)` | Takes a spectator's side-bet on a team or a fighter. |
| `ArenaBetting.CountSideBets(matchId)` | How many unsettled side-bets are riding on a match, so a mode change can be refused rather than voiding the whole book. |
| `ArenaBetting.MarkWalkedOut(matchId, src, citizenid)` | Marks this player's unsettled bets as placed by somebody who then left, so the dead-pick refund never hands them back, and trims a fighter's stake to what a non-fighter may hold. |
| `ArenaBetting.ReturnBetsOn(matchId, pick)` | Hands back every unsettled side-bet on one pick, because that pick can no longer win. |
| `ArenaBetting.SettleSpectatorBets(matchId, winningPick)` | Settles every side-bet on a match. |
| `ArenaBetting.PayOutstanding(src)` | Pays one character everything this resource owes them from a refund that could not be delivered. |
| `ArenaBetting.SweepUnpaid()` | Pays everybody on the server whatever they are still owed. |
| `ArenaBetting.Outstanding()` | How much this resource still owes, across how many characters. |
| `ArenaBetting.OwedReport()` | Every payout and refund the arena could not deliver, as lines, with what each one is for and whether a restart would forget it. On the admin tablet under **Tools → Money owed**. |
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

#### `server/match.lua` — 10 functions

| Function | What it does |
|---|---|
| `ArenaMatch.UnplaceAuto(match)` | Puts back the sides `Begin` handed to players who never picked one, for an exit back to the lobby that lives outside this file -- the host's Stop The Countdown. Answers whether it moved anybody. |
| `ArenaMatch.Begin(matchId, requestedBy)` | Validates a lobby and runs the countdown players are held for -- it re-checks the roster every second and drops the room back to the lobby the moment it no longer qualifies, which is why `ArenaLobby.MayLeave` refuses a voluntary leave for its whole length. A disconnect is never refused. |
| `ArenaMatch.Start(matchId)` | Teleports everybody in, hands out the loadouts, and starts the frozen countdown that ends with weapons live. |
| `ArenaMatch.RememberDamage(victimSrc, attackerSrc)` | The server watched one fighter land a hit on another; remember it for five seconds. Called once per landed hit from `server/dispatch.lua`'s `weaponDamageEvent` handler, which is the only place this resource sees a bullet. `OnDeath` reads it ONLY when the dying client named nobody on the roster -- a claim naming a fighter in the round keeps its own answer, refusal included -- and runs what it names through the same `resolveKiller` checks as any claim. Hits on a fighter who is already dead are not recorded. The packet is the shooter's own client talking, so a modified client can plant an entry; the roster, team, fence, distance, alive and five-second checks bound what that buys. Stores a fact, never a verdict. |
| `ArenaMatch.OnDeath(src, killerSrc, serverSaw, why, causeHash)` | One player died. `serverSaw` marks a death the dead-sweep found rather than the client reporting; `why` is for the log alone; `causeHash` is the weapon hash the dying client read off its own ped -- the only way the server can name what killed somebody, used to print the TEAMKILL line and to revoke a sparing the killer's rung would otherwise have earned. |
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

#### `client/dispatch.lua` — 8 functions

| Function | What it does |
|---|---|
| `ArenaDispatch.IsInArena()` | Whether this player is currently in an arena match. |
| `ArenaDispatch.MatchId()` | The match this client believes it is in, or nil. |
| `ArenaDispatch.Enter(matchId)` | Calls the operator's own mute exports and latches the match id. No game setting is touched. |
| `ArenaDispatch.Exit()` | Undoes Enter(), exactly. Safe when nothing is active. |
| `ArenaDispatch.ClearDeadState(ped)` | Puts an arena casualty back on their feet in the same instant they went down, held frozen, invisible and untouchable until the server says what happens next. |
| `ArenaDispatch.ReleaseDeadState(ped)` | Undoes ClearDeadState's holding pattern, putting each property back to the reading taken before the hold. Does nothing at all when no casualty is being held. |
| `ArenaDispatch.HeldPedState()` | A copy of what the ped really was before the hold was taken — `{ visible, collision, frozen }`, or nil when nothing is held. client/spectate.lua reads it instead of the ped, because by the time an eliminated fighter reaches the camera the hold has already hidden them. |
| `ArenaDispatch.IsHoldingDeadState()` | Whether a casualty is being held right now. client/spectate.lua asks it before it stands a watcher back up. |

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

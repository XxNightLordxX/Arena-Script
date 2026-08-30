# Crimson Arena

A configurable PvP arena for FiveM servers running Qbox. Players walk up to an NPC at the lobby, open a red-and-black panel, pick their weapons, their ammo and their side, and fight it out on grounds you define in `config.lua`. An optional entry fee is held in escrow for the length of the round and paid to the winners when it ends.

---

## What it does

Everything below is in the shipped code. Where something is off by default, or is a config key that nothing reads yet, it says so.

**Getting in**

- An NPC at `Config.Lobby.ped.coords` with an ox_target option, a ground marker with a keypress, or both — `Config.Lobby.interaction` picks. Ships as `'ped'`.
- A map blip at the lobby. On by default.
- `/arena` opens the same panel from anywhere. Set `Config.UI.command = nil` to register no command.

**Staying out of everyone else's way**

- Police and EMS are kept out of the arena — `Config.Dispatch`, built for a custom dispatch script rather than GTA's five-star system. An arena death never registers long enough for a medical script's polling loop to page an ambulance, which needs nothing from anyone. Alerts your own dispatch script sends need one line in that script, and there are three ways to write it: entry/exit events it can listen to, a server-written state bag it can read, or its own ignore export for this resource to call. Both switches on by default; the vanilla wanted-system handling ships off. See [Keeping police and EMS out of the arena](#keeping-police-and-ems-out-of-the-arena).

**The panel**

- Vanilla HTML/CSS/JS, no framework and no build step. Five screens — Matches, Lobby, Loadout, Bets, Leaderboard — plus a live scoreboard overlay during a round (`Config.UI.showMatchHud`).
- Every colour comes from `Config.UI.theme` at runtime. Recolouring config recolours the panel; nothing is hard-coded.
- `Config.UI.sounds` is read into the snapshot the panel receives, but **nothing in the panel plays a sound**. The switch currently does nothing.

**Weapons and ammo**

- The weapon list is `Config.Loadouts.weapons`. Delete an entry or set `enabled = false` and it is gone from the arena — the server refuses it even when a modified client asks for it by name.
- Each weapon carries its own ammo block: `options` is what the picker offers, `max` is the ceiling the server clamps to. A weapon with no `options` (melee) is handed out at `default` and shows no ammo row.
- `weaponSlots` caps how many weapons one player may take. `alwaysGive` is added on top and cannot be spent away.
- Body armour is picked the same way. `Config.Loadouts.allowChoose = false` hides both pickers and hands everyone `Config.Loadouts.fixed`.

**Teams**

- Players pick their own side (`Config.Teams.allowChoose`).
- **Uneven teams are legal by default** (`allowUnequal = true`). 7v1 starts. The pot splits evenly across the winning team, so stacking a side dilutes what winning on it is worth rather than guaranteeing it.
- Four teams ship; two are enabled. Enabling a third needs no code change — give it spawn points in each arena's `teamSpawns` or it falls back to the shared list.
- `Config.Teams.friendlyFire` does **not** block the damage. It decides whether a teammate's kill is *credited*: with it off the victim still dies and still spends a life, but nobody scores.
- `showTeamBlips` and `showEnemyBlips` are **not implemented**. No blips are drawn during a round whatever they are set to.

**Matches**

- `Config.Match.maxPlayers = 0` — any number of players in one match. Several matches can run side by side (`maxConcurrentMatches = 0` for no ceiling).
- Modes: **Free For All** and **Team Deathmatch** are on. **Gun Game ships disabled and its weapon ladder is not implemented** — turning it on gives you a second free-for-all in which players keep their own chosen loadouts.
- Win conditions: `last_standing` (default), `most_kills`, `score_limit`. A tie is a draw and refunds rather than picking one of two equal scores.
- Lives, respawn delay, a round clock (`roundTimeSeconds = 0` for none), a lobby countdown players can still back out of, and a frozen start countdown.
- Per-arena boundary sphere: a warning, then damage per tick until the player comes back. `boundary.enabled = false` for an open arena.
- Optional per-arena weather and time overrides. Both `nil` by default.
- Eliminated players get an orbiting spectator camera and can cycle between the fighters (`spectateOnElimination`).
- Players get back the weapons, ammo, armour and health they walked in with (`Config.Match.restoreLoadoutOnExit`, on by default) on every path out of the arena — round end, an aborted match, leaving or disconnecting mid-round, and a resource restart. Health comes back whatever that setting says: nobody leaves the arena as a corpse.

**Betting**

- One switch — `Config.Betting.enabled` — hides every bet control and makes the server reject any bet that arrives anyway.
- Entry fees are held in escrow, not tracked against a balance. Payout is `winner_takes_all` (default), `top_three` or `per_kill`, with an optional house cut.
- Spectator side-bets on a team or a fighter, on by default, paid at a fixed `oddsMultiplier` by the house. They never touch the fighters' pot.
- A match below `minPlayersToPayOut` refunds the pot instead of paying it out.

**Leaderboard**

- All-time, in MySQL through oxmysql, in a table the resource creates itself.
- `Config.Database.enabled = false` keeps the same numbers in memory for the length of the server run. Matches, betting and payouts are unaffected.

**Operations**

- `/arenaadmin` to list, force-stop or wipe matches, gated on ACE groups.
- A Discord webhook for match results and payouts. **Ships disabled** (`Config.Webhook.enabled = false`).
- Server-authoritative throughout: nothing a client sends about a weapon, ammo count, team, match id, bet or kill is trusted. Every one is re-checked against config before it is acted on.
- `Config.Permissions.joinJobs` gates who may join, the same way `createJobs` gates who may create. Both ship empty, and an empty list means everyone.

---

## Requirements

| Resource | Why |
|---|---|
| [qbx_core](https://github.com/Qbox-project/qbx_core) | player objects, character data, money |
| [ox_lib](https://github.com/overextended/ox_lib) | notifications, callbacks, the locale loader |
| [ox_target](https://github.com/overextended/ox_target) | the option on the lobby NPC |
| [oxmysql](https://github.com/overextended/oxmysql) | the leaderboard table |

**oxmysql is a hard dependency even with `Config.Database.enabled = false`.** It is listed in `fxmanifest.lua`'s `dependencies` block, and FXServer checks that list *before it ever reads `config.lua`* — so no setting in this resource can route around it. The resource will not start without oxmysql present and started.

Turning the database off means this resource sends oxmysql no queries and needs none of its own tables. It does not mean you can uninstall oxmysql.

## Installing

1. Drop the folder into your resources directory. **It must be named exactly `crimson_arena`.** The panel's NUI calls are addressed to `https://crimson_arena/...`, so a renamed folder gives you a panel that opens and answers no button.
2. Add it to `server.cfg`, after its dependencies:

   ```cfg
   ensure oxmysql
   ensure ox_lib
   ensure ox_target
   ensure qbx_core
   ensure crimson_arena
   ```

3. There is no `.sql` file to import. `crimson_arena_stats` is created on first start, and only when `Config.Database.enabled = true`.
4. Edit `config.lua`. At minimum move `Config.Lobby.ped.coords` and `Config.Lobby.returnCoords` somewhere on your map, and check the two shipped arenas suit you.
5. Start the server and read the console. Config problems are printed by name at start — they are warnings, not failures, and the resource keeps running:

   ```
   [crimson_arena] CONFIG: Config.Arenas["yard"] has no spawns -- players would have nowhere to land.
   [crimson_arena] Crimson Arena ready
   ```

6. Replace `html/images/logo.png` with your own. Keep the filename — an image `fxmanifest.lua` does not list is silently not sent to clients and renders as nothing, with no error saying why.

Player-facing text lives in `locales/en.json`. To translate it, copy the file to `locales/<code>.json`, **add that filename to the `files` block in `fxmanifest.lua`** — a locale file the manifest does not list is never sent to clients — and set ox_lib's locale convar.

---

## Configuring

`config.lua` is the only file an operator needs to edit. Every snippet below is lifted from it.

### Adding a weapon and its ammo options

Add an entry to `Config.Loadouts.weapons`. `key` is what the panel and the wire use and must be unique; `weapon` is the real GTA weapon name and is what is actually given.

```lua
{
    key = 'microsmg',
    weapon = 'WEAPON_MICROSMG',
    label = 'Micro SMG',
    category = 'automatic',
    enabled = true,
    ammo = { default = 120, options = { 60, 120, 250 }, max = 400 },
    components = {},
    tint = 0,
},
```

`options` is what the player may choose from. `max` is the hard ceiling the server clamps to no matter what arrives on the wire.

An **off-list request is refused, not rounded** — asking for 121 rounds gets you `default`, not 120. Rounding to the nearest legal value would let a modified client walk a number up past a preset by asking for one just above it.

A weapon with no choice to make sets `options = nil`. The panel shows no ammo row and the server hands out `default`:

```lua
ammo = { default = 1, options = nil, max = 1 },
```

Removing a weapon is `enabled = false`. That genuinely removes it — it does not merely hide a button.

### Turning betting off

```lua
Config.Betting = {
    enabled = false,
    ...
}
```

That is the whole change. Every bet control disappears from the panel, every match is free to enter, no stake is ever taken, and the server rejects any bet that arrives anyway. Nothing else needs touching.

To keep matches free but leave spectator side-bets running, leave `enabled = true` and turn off the entry fee instead:

```lua
entryFee = {
    enabled = false,
    ...
},
```

### Adding a team

Set `enabled = true` on one of the two that ship switched off, or add your own to `Config.Teams.list`:

```lua
['bone'] = {
    label = 'Bone',
    color = '#d8d2c4',
    blipColor = 0,
    enabled = true,
    order = 3,
},
```

Every team mode offers it immediately. Give it spawn points in each arena's `teamSpawns` or it falls back to that arena's shared `spawns` list — which works, but puts both sides in the same place.

The uneven-teams switch is separate and lives above the list:

```lua
allowUnequal = true,            -- any split is fine: 5v1, 8v2
maxTeamSizeDifference = 1,      -- only consulted when allowUnequal = false
requireBothTeamsOccupied = true,
maxTeamSize = 0,                -- 0 = unlimited players per team
```

### Adding an arena and its spawns

```lua
['docks'] = {
    label = 'The Docks',
    description = 'Containers and long sightlines.',
    enabled = true,

    spawns = {
        vector4(1200.10, -3100.50, 5.90, 180.0),
        vector4(1188.44, -3092.10, 5.90, 270.0),
    },

    teamSpawns = {
        crimson = { vector4(1188.44, -3092.10, 5.90, 270.0) },
        ash     = { vector4(1200.10, -3100.50, 5.90, 90.0) },
    },

    boundary = {
        enabled = true,
        center = vector3(1194.00, -3096.00, 5.90),
        radius = 70.0,
        warningSeconds = 5,
        damagePerTick = 8,
        tickMs = 1000,
    },

    weatherOverride = nil,
    timeOverride = nil,     -- e.g. { hour = 22, minute = 0 }
},
```

**You do not need one spawn point per player.** Points are handed out round-robin and each player is scattered within `Config.Match.spawnScatterRadius` of the one they drew, so twenty players share four points without stacking inside each other.

`teamSpawns` keys must match `Config.Teams.list` keys. A team with no entry falls back to `spawns`.

### maxPlayers = 0 means unlimited

```lua
Config.Match = {
    minPlayers = 2,
    maxPlayers = 0,             -- 0 = UNLIMITED
    maxConcurrentMatches = 0,   -- 0 = unlimited matches side by side
    ...
}
```

Zero is the "no ceiling" value nearly everywhere in `config.lua` — `maxPlayers`, `maxTeamSize`, `maxPot`, `maxConcurrentMatches`, `roundTimeSeconds` (no time limit), `idleLobbyTimeoutSeconds` (never expire). It never means "nobody".

The one place zero means *now* rather than *never* is `Config.Betting.spectatorBets.closeAfterStartSeconds`, where it closes side-bets the moment the round begins. It is spelled out in the comment next to it.

### Keeping police and EMS out of the arena

An arena is a place where people shoot each other on purpose. Left alone, every round calls the police for shots fired and every death calls EMS for a person down, and your emergency services spend the evening driving to a fight nobody wants them at.

`Config.Dispatch` deals with this, and it is built for a **custom dispatch script** rather than GTA's five-star wanted system. Both switches are on by default:

```lua
Config.Dispatch = {
    suppressPoliceShotsFired = true,
    suppressAmbulanceDown = true,
    ...
}
```

**Start here: the one thing no resource can do.** Your dispatch script decides to send an alert inside its own event handlers. Nothing in FiveM can reach into another resource and cancel that — not this script, and not any script claiming otherwise. So the job is to hand your dispatch script the facts it needs to decline. There are three ways to read the same fact, all live at once. Use whichever is least work in the script you are editing.

**Form 1 — this resource tells you.** Server events fired when a player is put into an arena and when they leave, so your script keeps its own ignore list without polling anything:

```lua
AddEventHandler('crimson_arena:dispatch:enter', function(src, matchId)
    MyDispatch.Ignore[src] = true
end)

AddEventHandler('crimson_arena:dispatch:exit', function(src, matchId)
    MyDispatch.Ignore[src] = nil
end)
```

Both are **server** events and are never sent to a client — who may be ignored by dispatch is not a decision a client gets a say in. Rename them with `custom.enterEvent` / `custom.exitEvent`, or set either to `nil` to fire nothing.

If your dispatch script restarts mid-round it comes back with an empty ignore list and starts alerting on a fight already in progress. Name it in `custom.resyncResources` and every player currently in an arena is re-announced the moment it comes back up:

```lua
resyncResources = { 'my_dispatch' },
```

**Form 2 — you read a flag.** A replicated state bag, readable from either realm with no call and no event:

```lua
if Player(src).state.crimsonArena then return end     -- server
if LocalPlayer.state.crimsonArena then return end     -- client
```

Drop that at the top of whatever sends the alert. Rename the key with `custom.stateBagKey` if `crimsonArena` collides with something you already use.

**Form 3 — this resource calls you.** If your script already has its own ignore or disable export, name it and it is called with `true` on entry and `false` on exit:

```lua
disableExports = {
    { resource = 'my_dispatch', export = 'SetIgnoredPlayer' },
},
```

Nothing ships enabled there, because calling an export that means something different on your build is worse than not calling it. An entry naming a resource that is not running, or an export that does not exist, is skipped with one console warning — it will not error and it will not stop a match starting.

There are also exports, for a script that would rather ask than listen — see [Exports](#exports).

**The state bag is written by the server, never the client.** That is a security decision rather than a tidy one: a replicated bag set from a client can be set by *any* client, so a player who had never been near the arena could pin the flag on themselves and have your dispatch script politely ignore them robbing a bank. The flag goes up when a player is placed in the arena, not when they join the lobby — somebody sitting in a menu choosing a rifle is not in a fight.

#### The person-down alert, stopped at source

This one needs nothing from anybody, and it is on by default.

Most medical scripts spot a casualty by watching whether a player is dead, on a loop running somewhere between twice a second and once a second. With `clearDeadStateImmediately`, an arena death is reported to the server and the body is put back on its feet in the same instant — frozen, invisible and untouchable until the server says whether they respawn or are out. That loop never sees a dead player to report. It also makes respawning feel sharper, which is why it is on even for servers with no medical script at all.

**The honest limit:** a script that hooks the death *event* rather than polling the death *state* still fires, because the player really did die. Use Form 1 or Form 2 above for those. This is not a substitute for them.

#### GTA's own five-star system

`Config.Dispatch.vanillaPolice.enabled` ships **false**, on purpose.

If you run a custom dispatch script you have almost certainly disabled the vanilla wanted system server-wide already, and touching these natives on top of that ranges from pointless to actively harmful — plenty of custom systems drive their own logic off the native wanted level, and pinning it to zero mid-match would fight them for it.

Turn it on only if NPC police still respond to gunfire on your server. It stops NPC cops being dispatched, stops them reacting to the player, and pins the wanted level at zero for the match. Everything it changes is restored on the way out, wanted stars included — walking into an arena is not an amnesty.

---

### Config keys nothing reads yet

None. Every key in `config.lua` is read by something.

This section used to list six that were not, and it is kept — empty — on
purpose: it is the right place to record the next one, and an operator who
has read this file once will come back looking for it before they conclude a
setting is broken.

---

## How a round plays out

1. **The lobby.** A player walks up to the NPC and picks the ox_target option, stands in the marker and presses E, or types `/arena`. The panel fetches the current snapshot from the server before it takes focus, so it never opens on an empty frame.

2. **Create or join.** The Matches screen lists every open match with its arena, mode, head count, pot and state. Creating one asks for an arena, a mode and — when entry fees are on and `hostSetsForEveryone = true` — one fee everybody in that match pays.

3. **The stake is taken at the door.** Joining takes the entry fee *before* the player is added to the match. A stake that cannot be taken aborts the join and leaves nothing behind: no seat, no place in the join order, nothing to unwind.

4. **Pick a side, pick a loadout.** In a team mode the team picker is shown and any split is legal. In the Loadout screen the player picks up to `weaponSlots` weapons, an ammo amount for each and an armour level. What the panel shows and what the server will allow come from the same file, so the preview and the real thing cannot disagree.

5. **Ready up.** With `autoStartWhenAllReady = true` the match starts on its own once everyone has readied and `minPlayers` is met. Otherwise the host presses start (`onlyHostCanStart`).

6. **Lobby countdown.** `lobbyCountdownSeconds` of a countdown players can still back out of. If someone leaves and the lobby drops below what it needs, the countdown stops and the lobby goes back to waiting — nobody loses their seat.

7. **In.** Everyone is teleported to a spawn point, scattered, frozen, and handed their loadout. Loadouts are **re-resolved at this moment** against the live catalogue, not replayed from what was stored — a weapon an operator switched off since is dropped here rather than granted.

8. **Live.** After `startCountdownSeconds` the freeze lifts and weapons go live. The pause menu and the multiplayer overlay are blocked for the duration. A once-a-second sweep pushes the scoreboard, runs the round clock and checks the win condition.

9. **Deaths.** The victim's client reports the death and names a killer. That is a **hint**: the server checks the reporter is really in this live match and really alive, and that the claimed killer is somebody in the same match whom the mode would have let land the shot. A claim it cannot verify scores nobody — but the reporter is still eliminated, because that part was never in doubt.

10. **Lives and elimination.** A player with lives left respawns at a fresh point with a fresh loadout after `respawnDelaySeconds`. Out of lives, they are eliminated, ranked, and dropped into the spectator camera.

11. **The end.** Last player or team standing, the score limit, or the clock running out. Two players who die in the same tick are both counted before anything is decided, so a double knockout is a draw rather than a race between two corpses.

12. **Payout.** The pot is settled, the leaderboard is written, side-bets are judged, escrow is cleared, and everyone is teleported to `Config.Lobby.returnCoords` with their own weapons, armour and health back and a results board showing the scoreboard, their placement and what they earned.

---

## How the money is handled

This is the part worth reading twice.

**One file moves money.** `server/betting.lua` is the only place in the resource that calls `AddMoney` or `RemoveMoney`. Nothing else can.

**It is escrow, not bookkeeping.** A stake leaves the player's account the moment they join and is held against the match id. From then on that money exists in exactly one place — the escrow table — until it is refunded or paid out. Nothing reads a balance to work out what is owed, because a balance is a running total and a running total cannot tell a refund that happened twice from one that never happened at all.

Three rules hold the invariant up:

- A stake is recorded **only after** the removal actually succeeded. A failed take leaves the player's account untouched and the match holding nothing.
- A settled stake is **marked, not deleted**. A second payout of the same stake is refused and printed rather than silently doubled.
- A match id is never dropped while it still holds escrow. `Clear` refuses, loudly, and the money stays reachable by a later refund. A leaked table entry is a bug somebody can find later; a swallowed pot is one nobody can.

**Two separate pools.** The entry-fee pot is what the fighters are playing for, and `maxPot` caps it. Spectator side-bets are the house's action, paid at `oddsMultiplier`, and live in their own table — a bystander cannot change what the winner takes home.

### What happens when…

| Event | The money |
|---|---|
| A player leaves a lobby that has not started | Refunded in full, unless `Config.Betting.refundOnDisconnectBeforeStart = false`, in which case the stake stays in the pot and is won by whoever takes the match. |
| A player disconnects from a lobby | The same rule, deliberately. That key does not distinguish a rage-quit from a crash, because a rule that charged only genuine disconnects would take money from players whose game crashed and hand it back to the ones who left on purpose. |
| A player leaves or disconnects **mid-round** | Forfeited to the pot by default. `Config.Betting.refundOnDisconnectDuringMatch = true` refunds them instead. |
| The host cancels the lobby | Every stake refunded, match closed — unless `Config.Betting.refundOnCancel = false`, in which case the stakes are **forfeited and leave the economy entirely**. See below. |
| A lobby sits idle past `idleLobbyTimeoutSeconds` with nobody ready | Closed, every stake refunded. |
| Everybody disconnects mid-round | The round is aborted, not settled. Every stake and every side-bet goes back — there is nobody to declare a winner over. |
| The round ends in a draw | Refunded. Paying one of two equal scores out of the other's stake is a coin toss with somebody else's money. |
| The round ends below `minPlayersToPayOut` | Refunded. This is what stops two friends farming each other. |
| An admin runs `/arenaadmin stop` or `wipe` | Aborted and refunded, whatever state the match was in. |
| **The resource stops or the server restarts** | Every live match is aborted on the way down, which refunds every stake in full, and only then are queued stat rows flushed. The handler is deliberately synchronous — a stop handler that yields may never be resumed, and a refund that never resumes is the exact bug it exists to prevent. |

### Where a forfeited pot goes

`Config.Betting.refundOnCancel = false` is the one setting that makes closing a lobby cost something, and the money it takes goes **nowhere**. It is kept the same way the house cut of a settled pot and a losing side-bet are kept: this resource has no house account to credit, so the money leaves the economy at the point it leaves escrow.

That is the point of the setting. It exists to deter a host who fills a lobby, collects everybody's stake and closes it — and a deterrent that handed the pot to somebody would only move the abuse to whoever received it.

Every forfeit prints a `FORFEIT:` line to the console and goes to the webhook regardless of `logPayouts`, because an operator running a house account by hand is the only person who can put that money anywhere.

Only a **host cancelling** forfeits. An idle-timeout close, an admin force-stop, the last player walking out and a resource restart all still refund in full — an operator punishing a host who calls their own match off has not asked to punish a lobby the server itself closed.

### When a payment cannot be made

A refund that fails — almost always because the player has already left — is **left held and still owed**. It is not written off. A later refund tries again, `Clear` goes on refusing to drop the match, and the console says so:

```
[crimson_arena] REFUND FAILED: 1000 owed to John Doe (citizenid ABC12345) on match m4f2a1 -- the stake stays held.
```

A *payout* that cannot be delivered is different: the pot has already been divided among everyone else, so it cannot be rolled back without changing what they were paid. It is logged for a human to settle by hand, and sent to the webhook if one is configured:

```
[crimson_arena] PAYOUT UNDELIVERED: 4000 owed to 12 on match m4f2a1 -- they are not on the server. Settle by hand.
```

Turn `Config.Webhook.enabled` on and set `logPayouts` if you want these in Discord. Undeliverable-money notices are sent whatever `logPayouts` says — an operator who turned payout logging off still needs to hear about a player who is owed.

Every movement carries a transaction reason of the form `crimson_arena:<kind>:<matchId>` (`stake`, `refund`, `payout`, `sidebet`, `sidebet_payout`, `sidebet_refund`), so a server's money log can be grepped for one match.

---

## Commands

| Command | Where | Who |
|---|---|---|
| `/arena` | client | anyone. Opens the panel. The name comes from `Config.UI.command`; set it to `nil` to register nothing. |
| `/arenaadmin list` | server | admins. Lists every match with its state, head count and pot. |
| `/arenaadmin stop <id>` | server | admins. Aborts one match and refunds everybody. |
| `/arenaadmin wipe` | server | admins. Aborts every match and refunds everybody. |

"Admins" means the ACE groups in `Config.Permissions.adminGroups`, checked as both `group.<name>` and a bare `<name>` because servers hand admin out both ways. The server console (source 0) always qualifies.

An **empty `adminGroups` list means nobody**, unlike the job lists elsewhere in `Config.Permissions` where empty means everyone. Reading empty as "everyone" is right for an arena that is open to the server; applied to force-stop and wipe it would hand every player the ability to end other people's matches.

## Exports

The arena owns its own state, so it exposes only the one fact another resource has a legitimate reason to ask about: whether a given player is currently in a match. That exists so your dispatch and medical scripts can decline to send an alert about a fight nobody needs telling about — see [Keeping police and EMS out of the arena](#keeping-police-and-ems-out-of-the-arena).

| Export | Realm | Returns |
|---|---|---|
| `exports.crimson_arena:IsPlayerInArena(src)` | server | `true` while that player is in a live match |
| `exports.crimson_arena:GetPlayerMatchId(src)` | server | the match id, or `nil` |
| `exports.crimson_arena:GetArenaPlayers()` | server | `{ [serverId] = matchId }` for everyone currently fighting |
| `exports.crimson_arena:IsInArena()` | client | `true` while *you* are in a live match |
| `exports.crimson_arena:GetArenaMatchId()` | client | your match id, or `nil` |

These report; they do not enforce. Calling them changes nothing.

The same fact is also a replicated state bag — `Player(src).state.crimsonArena` on the server, `LocalPlayer.state.crimsonArena` on the client — for scripts that would rather read than call.

What this resource *consumes* from others:

- `exports.qbx_core:GetPlayer(src)` — every player lookup
- `exports.ox_target:addLocalEntity` / `removeLocalEntity` — the lobby NPC's option

If you need to integrate, the surface is the network layer rather than an export:

- `lib.callback` `crimson_arena:server:getState` returns the full state snapshot for the calling player.
- Client → server events are all prefixed `crimson_arena:server:` and all re-validate everything they receive.
- Server → client events are all prefixed `crimson_arena:client:`.

Anything you build on those is subject to the same rule the rest of the resource follows: the server does not trust what it is told.

---

## Troubleshooting

### The panel does not open

- **The folder must be named `crimson_arena`.** The panel addresses its calls to `https://crimson_arena/<callback>`. Rename the folder and the panel opens, renders, and then ignores every button — with nothing in either console.
- Check start order in `server.cfg`. ox_lib must be started before this resource; a missing `lib` is a client-side error at load, not at open.
- The panel fetches the state snapshot *before* it takes focus. If the server is not answering, you get `The arena is not answering. Try again.` — look for a Lua error in the server console at start, which will have stopped the callback being registered.
- `Config.UI.command = nil` registers no command. Use the ped or the marker.
- If the mouse is captured and there is no panel, restart the resource — `onResourceStop` releases NUI focus, which is what makes that recoverable.

### The ped does not spawn

- `Config.Lobby.interaction` must be `'ped'` or `'both'`. `'marker'` spawns no NPC, on purpose. A typo falls back to `'ped'` and prints one line saying so:

  ```
  [crimson_arena] Config.Lobby.interaction is 'peds', which is not 'ped', 'marker' or 'both' -- falling back to 'ped'.
  ```

- A model that will not load prints its own line and leaves the lobby empty rather than hanging the client:

  ```
  [crimson_arena] Lobby ped model 'g_m_m_armboss_99' would not load -- no NPC spawned.
  ```

- `Config.Lobby.ped.coords.z` is the **ground z**. The resource drops the ped one unit itself. A ped hovering a metre in the air means the z came from a `/coords` reading taken while standing on something.
- The NPC standing there with no option to press is ox_target not running.
- Two NPCs standing on the same spot means something spawned one this resource did not. Its own ped is deleted on `onResourceStop`, so a plain restart cannot leave a duplicate behind.

### Weapons are not being given

- The key must be in `Config.Loadouts.weapons` **and** `enabled ~= false`. A disabled weapon is indistinguishable from an unknown one, deliberately — otherwise `enabled = false` would only be a UI hint.
- Rejected keys produce a toast naming them. A panel left open across a config reload is the usual cause.
- **Off-list ammo falls back to `default`, it is not rounded.** If players report getting less ammo than they picked, check that the value is in that weapon's `options` list and not above its `max`.
- `weaponSlots` caps how many weapons are honoured. Entries past the cap are silently dropped — the request still succeeds.
- `Config.Loadouts.allowChoose = false` ignores the picker entirely and hands out `Config.Loadouts.fixed`.
- `Config.Match.stripWeaponsOnEntry = true` (the default) wipes carried weapons on entry. If players are arriving unarmed, check that their chosen loadout resolved to something — a request that resolves to nothing still succeeds and carries only `alwaysGive`.
- Loadouts are re-resolved at match start against the live catalogue. Turn `Config.Debug` on to see what was dropped:

  ```
  [crimson_arena] [debug] dropped 1 loadout entr(ies) for 12 on match m4f2a1: grenadelauncher
  ```

### The leaderboard is empty

- **Rows are queued, not written immediately.** A match that ended seconds ago appears after the next flush — `Config.Database.flushIntervalMs`, 60 seconds by default — and a flush also runs on resource stop. This is the usual answer.
- The panel caches the board for 30 seconds on top of that. Reopening the panel does not force a fresh read.
- With `Config.Database.enabled = false` the board covers **this server run only** and resets on restart. That is the documented behaviour, not a fault.
- The table is created at start by the resource. If it is missing, oxmysql was not connected at that moment — check the oxmysql console lines and restart `crimson_arena` after the database is up.
- A query that cannot be answered falls back to this run's in-memory numbers rather than showing an empty panel, so a board with today's matches and nothing older is a database problem, not an empty table.
- Turn `Config.Debug` on to see flushes: `flushed 4 stat row(s)`.

### Nothing else fits

Set `Config.Debug = true` and restart. It is chatty by design — every stake, refund, payout, join and elimination is printed. Turn it back off on a live server.

---

## Development

```sh
luacheck .          # against .luacheckrc: exact native and global allow-list
tests/run.sh        # every tests/*_spec.lua under plain lua5.4
```

Both run on every push and pull request via `.github/workflows/lua-check.yml`, along with `luac5.4 -p` over every `.lua` file.

`shared/arena.lua` calls no native at all. That is what lets the test suite load the real, unmodified production file under plain Lua and exercise every rule directly.

---

## Licence

Copyright © John Allday. Proprietary — licensed to the purchaser for use on their own server. Not for redistribution, resale or public release.

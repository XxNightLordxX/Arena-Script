# Crimson Arena

A configurable PvP arena for FiveM servers running Qbox. Players walk up to an NPC at the lobby, open a red-and-black panel, pick their weapons, their ammo and their side, and fight it out on grounds you define in `config.lua`. An optional entry fee is held in escrow for the length of the round and paid to the winners when it ends.

---

## What it does

Everything below is in the shipped code. Where something is off by default, or is a config key that nothing reads yet, it says so.

**Getting in**

- An NPC at `Config.Lobby.ped.coords` with an ox_target option, a ground marker with a keypress, or both — `Config.Lobby.interaction` picks. Ships as `'ped'`.
- A map blip at the lobby. On by default.
- **No slash command ships.** The NPC is the way in, deliberately. `Config.UI.command` is `nil`; set it to a name like `'arena'` if you want a command as well, which is mostly useful for testing.

**Staying out of everyone else's way**

- Police and EMS are kept out of the arena — `Config.Dispatch`, built for a custom dispatch script rather than GTA's five-star system, and layered so that most of it works **without you editing either of those scripts**. Every match is fought in its own routing bucket, so no other player's client is ever sent arena gunfire, arena bodies or arena entities, and a dispatch or ambulance script running on one has nothing to detect. An arena death is put back on its feet in the same instant, so a medical script's polling loop never catches a casualty. At start the console prints which police and EMS resources you are really running and what the arena can do about each one. What is left over is the alert your own script sends about its own player, and that is one line in it. See [Keeping police and EMS out of the arena](#keeping-police-and-ems-out-of-the-arena).

**The panel**

- Vanilla HTML/CSS/JS, no framework and no build step. Five screens — Matches, Lobby, Loadout, Bets, Leaderboard — plus a live scoreboard overlay during a round (`Config.UI.showMatchHud`).
- Every colour comes from `Config.UI.theme` at runtime. Recolouring config recolours the panel; nothing is hard-coded.
- `Config.UI.sounds` switches the panel's own feedback tones on and off. They are short notes synthesised in the page rather than audio files, and the first panel of a session can be silent until the page has seen a click of its own — a browser will not start audio off the keypress that opened it.

**Weapons and ammo**

- The weapon list is `Config.Loadouts.weapons`. Delete an entry or set `enabled = false` and it is gone from the arena — the server refuses it even when a modified client asks for it by name.
- **24 entries ship and 20 of them are enabled**, in five categories. **Ten are melee and eight of those are on** — knife, baseball bat, machete, brass knuckles, hatchet, crowbar, golf club and switchblade — with the nightstick and the battle axe shipped off. The grenade launcher ships off as well.
- **Four MK II weapons ship** — Pistol, SMG and Assault Rifle enabled, Heavy Sniper off because explosive rounds are a different game. Those four are the ones Rockstar actually made special magazines for, so each carries its own `ammoTypes` list.
- Each weapon carries its own ammo block: `options` is what the picker offers, `max` is the ceiling the server clamps to. A weapon with no `options` (melee) offers no ammo choice and is handed out at `default` — with `max` left as the only limit on the wire for it, so every shipped melee entry sets the two to the same number.
- **Ammo types ship switched off** (`Config.Loadouts.ammoItems.enabled = false`), because the item names in `config.lua` are placeholders. Switched on, the round a player picks arrives as an item from your own ammo script and is taken back off them on the way out. See [Ammo types](#ammo-types--handing-out-your-own-ammo-items).
- `weaponSlots` caps how many weapons one player may take. `alwaysGive` is added on top and cannot be spent away.
- Body armour is picked the same way. `Config.Loadouts.allowChoose = false` hides both pickers and hands everyone `Config.Loadouts.fixed`.

**Teams**

- Players pick their own side (`Config.Teams.allowChoose`).
- **Uneven teams are legal by default** (`allowUnequal = true`). 7v1 starts. The pot splits evenly across the winning team, so stacking a side dilutes what winning on it is worth rather than guaranteeing it.
- Four teams ship; two are enabled. Enabling a third needs no code change — give it spawn points in each arena's `teamSpawns` or it falls back to the shared list.
- `Config.Teams.friendlyFire` does **not** block the damage. It decides whether a teammate's kill is *credited*: with it off the victim still dies and still spends a life, but nobody scores.
- `showTeamBlips` and `showEnemyBlips` put blips on the living fighters of your own match, tinted with the team's `blipColor`. They ship on and off respectively. A free-for-all has no teammates, so `showEnemyBlips` alone decides there.

**Matches**

- `Config.Match.maxPlayers = 0` — any number of players in one match. Several matches can run side by side (`maxConcurrentMatches = 0` for no ceiling).
- Modes: **Free For All** and **Team Deathmatch** are on. **Gun Game ships disabled**, and turning it on is not a second free-for-all: `gunGameLadder` replaces every player's own loadout with the rung they are standing on — on entry, on every promotion and on every respawn — each kill moves them up one, and finishing the ladder wins the round outright, ahead of whatever `Config.Match.winCondition` says. A rung naming a weapon that is not in the enabled catalogue is dropped and the ladder is that much shorter.
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
- A match fought by fewer than `minPlayersToPayOut` refunds the pot instead of paying it out — judged on the head count the round started with, so a player leaving cannot turn a decided match into a refund.

**Leaderboard**

- **The database ships off** (`Config.Database.enabled = false`), so out of the box the board keeps its numbers in memory for the length of the server run and resets on restart. Matches, betting and payouts are unaffected either way — nothing else in this resource reads the database.
- Turn it on for an all-time board, in MySQL through oxmysql, in a table the resource creates itself on first start (or that you import from `sql/install.sql` if your database user cannot `CREATE TABLE` at runtime).

**Operations**

- `/arenaadmin` to list, force-stop or wipe matches, gated on ACE groups.
- A Discord webhook for match results and payouts. **Ships disabled** (`Config.Webhook.enabled = false`).
- Server-authoritative throughout: nothing a client sends about a weapon, ammo count, team, match id, bet or kill is trusted. Every one is re-checked against config before it is acted on.
- `Config.Permissions.joinJobs` gates who may join, the same way `createJobs` gates who may create. Both ship empty, and an empty list means everyone.

---

## Requirements

Two, and both of them are already on every Qbox server:

| Resource | Why |
|---|---|
| [qbx_core](https://github.com/Qbox-project/qbx_core) | player objects, character data, money |
| [ox_lib](https://github.com/overextended/ox_lib) | notifications, callbacks, the locale loader |

Those two are the whole `dependencies` block in `fxmanifest.lua`, and that list is the one thing FXServer checks *before* it reads a single line of `config.lua` — so anything named there is required on every install no matter what you switched off. Three more resources are used when you ask for the features that need them, and each is checked at run time instead:

| Resource | Used for | Without it |
|---|---|---|
| [ox_target](https://github.com/overextended/ox_target) | the option on the lobby NPC | the ground marker goes up in the NPC's place, at the same spot, and players press **E** instead |
| [ox_inventory](https://github.com/overextended/ox_inventory) | [ammo items](#ammo-types--handing-out-your-own-ammo-items), and the stash that holds a player's own kit during a match | ammo items are not handed out, nobody is stripped, and the console says so once |
| [oxmysql](https://github.com/overextended/oxmysql) | the all-time leaderboard, and only when `Config.Database.enabled` is on — it ships **off** | the leaderboard covers the current server run |

None of those three is named in the manifest and none is imported by it, so with the shipped settings this resource starts on a server that has no database resource, no target script and no inventory script at all. Turn a feature on and the resource asks for what it needs at that moment; if the answer is no, it says so in the console once and carries on.

## Installing

Drag, drop, one line in `server.cfg`, start.

1. Drop this `Crimson-Arena` folder into your resources directory. It arrives named the way it should be named there, so there is nothing to rename — but **any folder name works** if you would rather use another: `crimson_arena`, `[custom]/whatever`, or the `-main` suffix a zip leaves behind. The panel asks the game what it was installed as rather than assuming.
2. Add one line to `server.cfg`, below wherever you already start qbx_core:

   ```cfg
   ensure Crimson-Arena
   ```

   Use whatever the folder is actually called. Nothing else needs adding, and there is no order to get right beyond being after qbx_core.

3. **You do not have to import any SQL.** `Config.Database.enabled` ships `false`, and nothing is created or queried while it is. Turn it on and `crimson_arena_stats` is created on first start; `sql/install.sql` holds the identical statement for the case where your database user cannot `CREATE TABLE` at runtime, which is a reasonable way to run a production server.
4. **Optional, and the arena works before you do any of it.** Edit `config.lua`: move `Config.Lobby.ped.coords` and `Config.Lobby.returnCoords` somewhere that suits your map, and check the two shipped arenas suit you — they are open ground at **Sandy Shores Airfield** and on the sand at **Vespucci beach**, with the coordinates offered as a starting point rather than a finished map.
5. Start the server and read the console. Config problems are printed by name at start — they are warnings, not failures, and the resource keeps running:

   ```
   [crimson_arena] CONFIG: Config.Arenas["docks"] has no spawns -- players would have nowhere to land.
   [crimson_arena] Crimson Arena ready
   ```

6. Replace `html/images/logo.png` with your own. Keep the filename — an image `fxmanifest.lua` does not list is silently not sent to clients and renders as nothing, with no error saying why. Then pick how it is used:

   | `Config.UI.logoStyle` | What it draws | Right for |
   |---|---|---|
   | `'mark'` (default) | a small square badge to the left of `title` and `subtitle` | a simple icon — a skull, a monogram, a shield |
   | `'banner'` | the logo across the header, with `title` and `subtitle` **not** drawn | a finished lockup that already contains your server name |

   Use `'banner'` when your logo has your server's name in it. In `'mark'` mode that name is printed twice: once as the panel's title, once as pixels too small to read. A full-scene artwork — skyline, vehicles, effects — is small at panel size either way, and reads far better cropped down to the part that identifies you: the badge alone for `'mark'`, the wordmark strip for `'banner'`.

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

A weapon with no choice to make sets `options = nil`. The panel offers no chips for it — it prints the count as fixed instead — and the player is handed `default`:

```lua
ammo = { default = 1, options = nil, max = 1 },
```

With no list to check a request against, `max` is the only limit that weapon has left on the wire: a modified client asking for a number between `default` and `max` is given it, because that is what `max` means everywhere else in the file. **Set `max` equal to `default` for a weapon whose count is meant to be fixed** — all ten melee entries ship that way, which is why nothing on the shipped catalogue has any headroom to ask into. Leave the two apart only when free-form ammo up to the ceiling is what you meant.

Removing a weapon is `enabled = false`. That genuinely removes it — it does not merely hide a button.

### Ammo types — handing out your own ammo items

If you run an ammo script where a round is an inventory item — `ammo-rifle`, `ammo-9`, a box of armour-piercing — this is how the arena hands one out and, more importantly, how it takes it back.

There are two halves and they are independent. A type may carry an **item**, which is yours; it may carry a **component**, which is GTA's; it may carry both, or neither. The item half is what this section is mostly about. The component half is [further down](#mk-ii-magazines-are-components-not-items).

#### It ships off, and that is deliberate

```lua
ammoItems = {
    enabled = false,
    ...
}
```

The item names in `Config.Loadouts.defaultAmmoTypes` — `ammo-rifle`, `ammo-rifle-fmj`, `ammo-rifle-ap` and the rest — are **placeholders**. They are the shape a name tends to take, not names that exist on your server.

Handing out an item name that does not exist is a **silent nothing**. The player picks armour-piercing, the match starts, and there is no ammunition in their inventory and no error anywhere they can see. What they report is not "the ammo item is misconfigured" — it is "the arena is broken". That is why this is the one loadout feature that ships off: an operator who has not read this section gets a working arena, not a mystery.

Turning it on is two steps and nothing else:

1. **Put your own item names in.** Edit the `item` field on every entry in `Config.Loadouts.defaultAmmoTypes`, and delete or `enabled = false` the ones you have no item for.
2. **Flip the switch.** `Config.Loadouts.ammoItems.enabled = true`.

One prerequisite: **`ox_inventory` must be running.** It is the only inventory this file knows how to talk to, and it is looked up fresh on every call rather than cached, so restarting your inventory resource does not leave the arena holding a dead handle. If ammo items are on and `ox_inventory` is not started, nobody is given anything and the console says so once per attempt:

```
[crimson_arena] ammo items are switched on but ox_inventory is not started -- nobody is being given any.
```

**Nothing checks your item names at startup.** The config validator checks weapon keys, ammo ceilings, spawns, teams and betting numbers; it does not and cannot know what items exist in your inventory. A wrong name surfaces on the first match that asks for it, in the server console, naming the item:

```
[crimson_arena] ammo: could not give ammo-rifle-ap x60 to 12 -- check that item exists on this server.
```

That is the line to grep for after you first switch this on. Read it as "this name is wrong, or that player's inventory is full".

#### Set the list once, override where you need to

`Config.Loadouts.defaultAmmoTypes` is the list, and it is **offered for every weapon that takes ammunition**. Set it once and you are done:

```lua
defaultAmmoTypes = {
    { key = 'standard',   label = 'Standard',        item = 'ammo-rifle' },
    { key = 'fmj',        label = 'FMJ',             item = 'ammo-rifle-fmj' },
    { key = 'ap',         label = 'Armour Piercing', item = 'ammo-rifle-ap' },
    { key = 'incendiary', label = 'Incendiary',      item = 'ammo-rifle-incendiary' },
    { key = 'hollow',     label = 'Hollow Point',    item = 'ammo-rifle-hollowpoint', enabled = false },
    { key = 'tracer',     label = 'Tracer',          item = 'ammo-rifle-tracer',      enabled = false },
}
```

`key` is what the panel and the wire use and must be unique in a list. `label` is what the player reads. `item` is the one you must edit. `enabled = false` hides an entry without deleting it.

Three levers, in order of how often you will want them:

| You want | Do this |
|---|---|
| The same types everywhere | Edit `defaultAmmoTypes`. Nothing else. |
| Different item names on one weapon — a pistol round and a rifle round are separate items | Give that weapon its own `ammoTypes = { ... }` list. It replaces the shared one for that weapon, it does not add to it. |
| No types at all on one weapon | `ammoTypes = false` on that weapon. An explicit `false` beats the shared default. |

**Melee is excluded automatically.** A weapon whose ammo `max` is 1 or less never inherits the shared list, because a weapon that carries one "round" is not carrying ammunition, it is carrying a bat. You do not have to write `ammoTypes = false` on the eight melee entries, and you should not: the rule is in the code, so a melee weapon you add later is excluded too.

**Which type a player gets when they express no preference** is `defaultAmmoType` — set per weapon, falling back to `Config.Loadouts.defaultAmmoType` for the whole list, falling back to the first enabled entry. That matters more than it sounds: it is what is issued for anything that never went through a player's choice at all.

An unknown or disabled type key arriving on the wire is **refused back to the default, not guessed at** — the same posture as an off-list ammo count. So shortening a list genuinely removes that round from the arena rather than merely hiding it.

#### `roundsPerItem`, when one item is a box

```lua
roundsPerItem = 1,
```

With ox_inventory's usual per-round ammo items this is 1: a player who picks 60 rounds is handed 60 items. If one item on your server is a **box of 30**, put 30 here and they are handed 2.

The division **rounds up**, on purpose. 61 rounds at 30 per box is three boxes, not two — rounding down would hand somebody 30 rounds when they asked for 60 and leave them wondering what happened. The reclaim takes back the same number of items that were issued, so the rounding is symmetric and nobody is short-changed or quietly enriched by it.

A value of 0 or below is treated as 1 rather than dividing by zero.

#### If the item will not go in

```lua
allowWeaponWithoutAmmoItem = true,
```

An `AddItem` can fail for reasons that have nothing to do with your config — most often a full inventory. This decides what happens then:

- **`true` (the default, and the friendlier one)** — the player fights, with the weapon and without the item. The failure is named in the console for you.
- **`false`** — the player is refused the round rather than sent in with an empty gun.

Either way the arena records **nothing** for an item that did not land. That is the important half: an item recorded as issued but never given would have the reclaim reach into that player's own pocket later and take one they brought with them.

#### The reclaim

**This is the part that matters, and it is the reason this feature is written as its own file rather than three lines in the match code.**

An arena that gives out two hundred armour-piercing rounds and does not take them back is an **ammo printer**: join, collect, walk out, repeat, sell. It is the same problem the entry-fee escrow solves for money, and it is solved the same way — everything issued is recorded against the player and the match that issued it, and removed again on **every** way out of the arena there is:

- the round ending normally, for fighters and for eliminated players watching from the spectator camera
- the player walking out mid-round
- the player **disconnecting** — including a drop between being handed the ammunition and the match recording them
- an admin `/arenaadmin stop` or `wipe`
- the round being abandoned because everybody left
- **the resource stopping or the server restarting**, which is handled first in the shutdown, before anything else tears down

(A host *cancelling* is not on that list because it cannot be: cancel is refused the moment anybody has been placed in the arena, which is the same moment ammunition is issued. There is never a cancel with rounds outstanding.)

```lua
```

The switch exists, it defaults to on, and turning it off makes the arena a source of free ammunition. It is there only for servers that genuinely want that. If you are not sure, you do not.

Three things worth knowing before you watch it run:

**A round the player already fired cannot come back, and that is expected.** They were given it to shoot. The reclaim asks the inventory for what it issued and gets what is still there; the shortfall is spent ammunition, not a fault. Do not read a partial reclaim as a bug.

**Anything that will not come out is named in the console rather than written off.** A silent teardown that took nothing back looks exactly like a clean one, so it is never allowed to look clean:

```
[crimson_arena] ammo: ammo-rifle-ap x60 issued to 12 on match m4f2a1 could not be taken back (left the arena). They fired it, dropped it, or are already gone.
```

The reason in brackets is the exit path — `left the arena`, `disconnected`, `resource stopping` — so a line tells you both what is outstanding and how the player left holding it.

**Reclaiming twice takes nothing twice.** Each record is marked as it is returned, and the exit paths overlap by design — a disconnect mid-round routes through the ordinary exit *and* is caught again by the disconnect handler. The second pass is a no-op. That is deliberate: two guards that both fire are safe, one guard that misses is an ammo printer.

The ledger removes **exactly what it issued**, by item and count, and nothing else. A player who walks in carrying a hundred rounds of the same item and fires none of them walks out with their hundred. Test that deliberately anyway — some inventory setups tie a weapon's in-game round count to the item backing it, and this resource grants and strips weapons with the game's own natives, which is a separate mechanism from the ledger. Whether the two reconcile on your build is a question only your server can answer.

Turn `Config.Debug` on to watch it work:

```
[crimson_arena] [debug] ammo: gave ammo-rifle-ap x60 to 12 on match m4f2a1
[crimson_arena] [debug] ammo: reclaimed 41 of 60 item(s) from 12
```

Nineteen rounds down the range is a fought match, not a leak.

#### What is *not* issued an item

Worth knowing before you go looking for a bug that is not there. Items are handed over **once**, at the moment a player is placed in the arena, for the weapons in the loadout they chose. Specifically:

- **`alwaysGive` weapons get no ammo items.** The house knife is the operator's own entry, not a picked weapon, and it never carries a type.
- **Gun Game rungs get no ammo items.** The ladder replaces a player's loadout with the rung's own weapon at the rung's own ammo count, and that path does not go through the type resolution.
- **Respawns do not issue more.** A player who dies and comes back is re-handed their weapon and its rounds in-game; no second item is put in their inventory. One loadout's worth per player per match is the whole of what the arena lends.

#### MK II magazines are components, not items

GTA's own special rounds — FMJ, hollow point, armour-piercing, incendiary, tracer, explosive — exist **only on MK II weapons**, and only as weapon **components**, not as anything an inventory can hold. That is why a type may carry a `component` as well as an `item`:

```lua
{ key = 'fmj', label = 'FMJ',
  item = 'ammo-rifle-fmj',
  component = 'COMPONENT_ASSAULTRIFLE_MK2_CLIP_FMJ' },
```

The two are independent and you can have either, both, or neither:

| Carries | What happens |
|---|---|
| `component` only | The magazine is attached to the weapon on entry. **This needs no inventory and works with `ammoItems.enabled = false`** — it is how the three enabled MK II weapons ship. |
| `item` only | Your ammo script's item is handed over and reclaimed. Works on any weapon that takes ammunition. |
| both | Both. The magazine is attached *and* the item is issued. |
| neither | The type still resolves and is still named in the loadout, and nothing is handed over. |

The component is appended to a **copy** of that weapon's `components` list, never to the config table itself — one player's chosen clip cannot leak into the next player's loadout.

Component names are only meaningful on MK II weapons. Adding a `component` to a plain Assault Rifle does nothing useful, because there is no magazine for it to attach.

**The one trap in the shipped config, and it will catch you.** All four MK II entries carry their **own** `ammoTypes` list — component names filled in, **no `item` field on any of them**. That is exactly right for a server with no ammo script. But a per-weapon list *replaces* the shared one, so if you switch ammo items on and edit only `Config.Loadouts.defaultAmmoTypes`, every weapon in the catalogue starts issuing items **except** the four MK II ones, which quietly keep handing out a magazine and nothing else. Add your `item` names to those four lists as well, or delete their `ammoTypes` lists so they inherit the shared one — at the cost of the MK II magazines, since the shared list carries no components.

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

`maxTeamSize` is enforced in all three places a player can end up on a side: picking one, being auto-assigned one at join with `allowChoose = false`, and being dropped onto the smallest side at start with `autoAssignIfUnchosen`. A player nobody has room for is left without a side and the start is refused for capacity, rather than being wedged onto a full team the lobby then cannot start with. **Set it against `Config.Match.maxPlayers`**: a lobby that admits more players than the sides have seats between them can be filled into a match that cannot start until somebody leaves.

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

`Config.Dispatch` deals with this. It is built for a **custom dispatch script and a custom ambulance script** rather than GTA's five-star wanted system, and it is deliberately layered — strongest first, and the strong ones need nothing from you:

| | Layer | Needs an edit to your dispatch or EMS script? |
|---|---|---|
| 1 | Every match is fought in its own routing bucket | **No.** On by default. |
| 2 | The death state is cleared in the same instant it is set | **No.** On by default. |
| 3 | A startup report naming what you run and what the arena does about it | **No.** It only tells you the truth. |
| 4 | Hooks your script can read: events, a state bag, exports | Yes — one line, and this is the one that always works. |
| 5 | Cancelling the alert event outright | No, but it is **best effort** and often does nothing. |

**Will it just work?** Mostly, and more than you would expect. Layers 1 and 2 are on out of the box. Between them, no *other* machine on your server is ever sent an arena fight to detect, and a medical script that finds casualties by polling the death state does not find one here. Nothing is pasted into anything, and nothing is asked of anybody.

**What do you have to do?** One thing, and only for one case: a dispatch script that watches the *arena player's own client* for gunfire. That is the one thing no resource can reach, and it takes one line in that script. It is spelled out under [the one limit](#the-one-limit-nothing-here-gets-past) below.

**How do you tell whether it is working?** Read the console at start, or type `/arenadispatch`. Layer 3 exists for exactly that question and answers it by name.

#### Layer 1 — the match is fought in its own network instance

```lua
isolation = {
    enabled = true,
    perMatch = true,
    firstBucket = 4210,
    populationEnabled = false,
    lockdownMode = 'relaxed',
},
```

A **routing bucket** is a separate network instance. Entities and events inside one do not replicate to players outside it. Every player the server puts into a match is moved into the match's bucket, and moved back out on the way home.

That single fact does most of the work here. A dispatch or ambulance script running on some other player's client is never *sent* arena gunfire, arena bodies or arena entities, so it has nothing to detect and nothing to report. There is no cooperation to ask for, no line to paste, and no way for the other script to be written that gets around it — it is not being asked to decline, it is being given nothing.

It is worth having even on a server with no dispatch script at all. Passers-by stop wandering into a live round, and arena gunfire stops being heard across the map.

What the settings do:

- **`enabled`** — off means every match is fought in the ordinary world in front of everybody, exactly as it was before this setting existed. It is opt-*out*, so an operator upgrading from an older `config.lua` gets it.
- **`perMatch`** — one bucket per match, so two matches running at once cannot see each other either. Switch it off and every match shares `firstBucket`: still hidden from the rest of the server, but two simultaneous arenas stand in one room hearing each other.
- **`firstBucket`** — the number allocated from, counting upwards to the first free one. **Bucket numbers are server-wide and shared with every other resource on the box**, so change this if something you already run lives in the 4210 range. A number is handed back when the match that held it ends, so a server running for a week does not walk off into somebody else's range.
- **`populationEnabled`** — ambient NPCs and traffic inside the bucket. Off, so a round is fought in an empty world. An NPC that does not exist cannot witness a firefight, panic in front of one, or be run over into somebody's incident report.
- **`lockdownMode`** — `'relaxed'` by default, and **not `'strict'` on purpose**. Weapons and props handed out during a match are entities created by the receiving client, and a strict bucket refuses them: the player arrives empty-handed with nothing on screen saying why. Only set `'strict'` if you have tested that loadouts still arrive on your build.

Things worth knowing before you turn it on for a live server:

- **The bucket is set by the server and never on a client's say-so.** A client that could pick its own instance could pick the one somebody else's match is being fought in, which is a spectating cheat and a griefing tool in the same request.
- **A player is put back in the bucket they were found in, not in bucket 0.** Restoring to zero is right only on a server that instances nobody; on one running apartments, heists or per-job worlds it would silently move players to the default world on the way out of the arena, with nothing telling them or you that it happened.
- **Spectators are moved into the match's bucket too.** Watch from outside it and the arena is an empty room — no fighters, no gunfire, and a camera pointed at a player the watching client does not have.
- **Everybody is returned on `onResourceStop`, first, before anything else in the shutdown.** A bucket lives in the server, not in this resource: stopping `crimson_arena` does not empty one. A player left behind in an arena instance is alone in an invisible copy of the map, cannot fix it themselves, and does not get it cleared by reconnecting.
- **A bucket is a network boundary, not a permissions boundary.** Server-side code still sees every player normally — a dispatch script's *server* half looping over players finds an arena player exactly as it always did. That is what layer 4 is for.
- **Proximity voice and anything else that follows client replication follows the bucket too.** In practice a fighter hears their match and nobody outside it. Check yours if that matters to you.

**And the limit, which is the reason the rest of this section exists:** a bucket hides the fight from every *other* machine on the server. It cannot hide an arena player's gunfire from **their own** client. See [the one limit](#the-one-limit-nothing-here-gets-past).

#### Layer 2 — an arena death is undone in the same instant

```lua
suppressAmbulanceDown = true,
clearDeadStateImmediately = true,
```

Most medical scripts spot a casualty by watching whether a player is dead, on a loop running somewhere between twice a second and once a second. The stock `baseevents` resource finds one the same way, which is where a great many "player died" handlers on a server ultimately come from.

With `clearDeadStateImmediately`, an arena death is reported to the server and the body is put back on its feet in the same instant — frozen, invisible and untouchable until the server says whether they respawn or are out. In practice that loop never has a dead player to find, and no ambulance is ever paged. The player sees no difference: they are held in place either way, waiting on the server. It also makes respawning feel sharper, which is why it is on even for servers with no medical script at all.

**The honest limit:** a script that hooks the death *event* rather than polling the death *state* still fires, because the player really did die. Layer 4 is the answer for those. This is not a substitute for it.

#### Layer 3 — the startup report, so you never have to guess

Every other layer is either invisible when it works or needs something from you. This one exists to tell you which.

Five seconds after the resource starts — five, because resource start order is not guaranteed and a dispatch script listed below this one in `server.cfg` has not started yet at zero — the arena looks up every police and EMS resource name it knows about, sees which are running on **your** server, and prints one short block naming each one and what it can do about it.

Nothing wired up yet, with Project Sloth's dispatch and the Qbox ambulance job running:

```
[crimson_arena] dispatch compat: 2 police/EMS resource(s) running.
[crimson_arena]   ps-dispatch          police+EMS  NOT muted -- needs the line below
[crimson_arena]   qbx_ambulancejob     EMS         NOT muted -- needs the line below
[crimson_arena] Isolation is on: no OTHER player's client can see the fight. An arena player's own client still can -- that is what the line below is for.
[crimson_arena]   Paste at the top of whatever sends the alert, in that script:
[crimson_arena]       if Player(src).state.crimsonArena then return end        -- server realm
[crimson_arena]       if LocalPlayer.state.crimsonArena then return end        -- client realm
[crimson_arena] Hooks configured: entry/exit events. /arenadispatch re-runs this report.
```

The same server once both are handled — one through its own ignore export, one through the entry/exit events:

```
[crimson_arena] dispatch compat: 2 police/EMS resource(s) running.
[crimson_arena]   ps-dispatch          police+EMS  muted automatically -- disableExports calls exports.ps-dispatch:SetIgnoredPlayer
[crimson_arena]   qbx_ambulancejob     EMS         assumed handled -- you named it in resyncResources, so it hears crimson_arena:dispatch:enter
[crimson_arena] Isolation is on: no OTHER player's client can see the fight.
[crimson_arena] Hooks configured: entry/exit events, 1 disableExport(s), 1 resyncResource(s). /arenadispatch re-runs this report.
```

Reading it:

| Row says | It means |
|---|---|
| `muted automatically` | The arena really calls something on that resource on entry and exit. Nothing more to do. |
| `assumed handled` | You named it in `resyncResources`, so you have evidently wired it to the entry/exit events. That is evidence, not proof — the report cannot see inside your script. |
| `NOT muted -- needs the line below` | Nothing in the arena reaches it. Paste the line it prints. |
| `Isolation is off` | Layer 1 is switched off, so every client on the server can see arena gunfire and arena bodies. |

`/arenadispatch` runs the whole detection again, live, and prints the same block — after installing a dispatch script, or after pasting the line it asked for, without a restart. It is gated on `Config.Permissions.adminGroups`, and the server console always qualifies. An admin who runs it in-game has no console to read, so they get the block as one notification as well.

**Nothing in the catalogue ships with a mute call, deliberately.** A third-party script's export names cannot be verified from inside this resource, and a guessed export name is the worst outcome available: it detects as present, reports itself as handled, and silently does nothing — strictly worse than admitting the resource is unhandled. Detection is what drives the report, and the report is the point.

Detected by name today:

| Kind | Resources |
|---|---|
| Dispatch boards (`police+EMS`) | `ps-dispatch`, `cd_dispatch`, `qs-dispatch`, `core_dispatch`, `rcore_dispatch`, `codem-dispatch`, `emergencydispatch` |
| Police (`police`) | `linden_outlawalert`, `origen_police`, `qbx_policejob`, `qbx_police`, `qb-policejob`, `wasabi_police` |
| EMS (`EMS`) | `qbx_ambulancejob`, `qbx_medical`, `qb-ambulancejob`, `wasabi_ambulance` |

If yours is not on that list the report says so and tells you where to add the name — `shared/compat/dispatch.lua`, one line. A name nobody runs simply never matches, so the list being generous with spellings costs nothing.

```lua
ArenaCompat.RegisterAdapter({ resource = 'my_dispatch', kind = 'police' })
```

`kind` is `'police'`, `'ambulance'` or `'both'`, and is only ever a label in the report. If you know the *real* ignore export for a script you run — read out of its own documentation, never one that merely sounds right — a registration may carry a `mute = function(src, active) ... end` as well, and the report will then say `muted automatically` about it. `src` is a server id and `active` is `true` on entry, `false` on exit; the call is made on the server, wrapped so that a throw on the far side cannot take a match start down with it. It rides `custom.enterEvent` / `custom.exitEvent`, so a mute with those set to `nil` has nothing to trigger it — and the report says exactly that rather than claiming a mute that cannot fire.

#### Layer 4 — the hooks, for the alert your own script sends

This is the layer that always works, and it is the one that covers the case layer 1 cannot. It is also the only place in this whole section where you edit somebody else's file.

**Start from what no resource can do.** Your dispatch script decides to send an alert inside its own event handlers. Nothing in FiveM can reach into another resource and cancel that decision — not this script, and not any script claiming otherwise. So the job is to hand your dispatch script the facts it needs to decline. There are three ways to read the same fact, all live at once. Use whichever is least work in the script you are editing.

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

Drop that at the top of whatever sends the alert. Rename the key with `custom.stateBagKey` if `crimsonArena` collides with something you already use. The value is a table — `{ active = true, matchId = '...' }` — so it is truthy in a match and `nil` otherwise.

**Form 3 — this resource calls you.** If your script already has its own ignore or disable export, name it and it is called with `true` on entry and `false` on exit:

```lua
disableExports = {
    { resource = 'my_dispatch', export = 'SetIgnoredPlayer' },
},
```

It is called **on the client**, with that boolean as its only argument — the player it is about is the client making the call. (For a server-side ignore export that wants a server id, register a `mute` instead: see [layer 3](#layer-3--the-startup-report-so-you-never-have-to-guess).)

Nothing ships enabled there, because calling an export that means something different on your build is worse than not calling it. An entry naming a resource that is not running, or an export that does not exist, is skipped with one console warning — it will not error and it will not stop a match starting. The startup report credits the resources this list names.

There are also exports, for a script that would rather ask than listen — see [Exports](#exports).

**The state bag is written by the server, never the client.** That is a security decision rather than a tidy one: a replicated bag set from a client can be set by *any* client, so a player who had never been near the arena could pin the flag on themselves and have your dispatch script politely ignore them robbing a bank. The flag goes up when a player is placed in the arena, not when they join the lobby — somebody sitting in a menu choosing a rifle is not in a fight.

#### Layer 5 — cancelling the alert event, and it is best effort only

**This is the weakest thing in this section, and if it is the only form you fill in you should assume your alerts are still going out.** It is here for the case where you cannot edit the sending script at all.

Name the events your dispatch or ambulance script raises in order to send an alert. The arena registers a handler on each one and calls `CancelEvent()` on it — but only when it can establish that the alert is about a player who is in a match right now:

```lua
cancelEvents = {
    -- An event a CLIENT triggers. `source` is the player who triggered it,
    -- and that is all this needs.
    'dispatch:server:shotsFired',

    -- An event another RESOURCE triggers on the server. There is no player
    -- behind it, so say which argument carries the server id of the player
    -- the alert is ABOUT. Count from 1.
    { event = 'dispatch:server:personDown', playerArg = 1 },
},
```

(A set keyed by event name — `['dispatch:server:shotsFired'] = true` — is accepted too.)

**Why it is only best effort, and there is no way to make it more.** `CancelEvent()` raises a flag and stops nothing by itself. The alert still goes out unless the code that raised the event checks `WasEventCanceled()` afterwards and decides to drop it, **and many scripts never check**. Worse, a script that does check inside its own handler only sees the flag if `crimson_arena` registered first — which comes down to the order resources start in your `server.cfg`, and is not something any resource can guarantee about another.

**It will not guess.** An event that arrives with no usable `source` and no `playerArg` is passed straight through untouched, and its name is printed once so you know to add one:

```
[crimson_arena] cancelEvents: "dispatch:server:personDown" fired with no player behind it, so it was left alone. If that event carries a server id, say which argument it is -- { event = 'dispatch:server:personDown', playerArg = 1 } -- or drop it from the list.
```

Cancelling a shots-fired call about somebody on the other side of the map is a far worse outcome than failing to cancel one about a fighter — it is the same silent hole the state bag's security note is written against, arrived at from the other direction — so anything doubtful is left alone.

**It only ever listens.** These are registered with `AddEventHandler` and never `RegisterNetEvent`. `RegisterNetEvent` is what makes an event triggerable by a client, and calling it on somebody else's server-only event name would let *any* player fire that event — turning a feature meant to silence false alerts into a way to forge real ones.

The list ships empty. The startup report counts what you put in it and labels it `(best effort)` there too.

#### The one limit nothing here gets past

**A dispatch script that polls the arena player's own client for gunfire cannot be stopped from outside it.**

If a script runs `while true do if IsPedShooting(PlayerPedId()) then ... end end` on the shooter's own machine, then layer 1 does not help — the bucket hides the fight from every *other* client, not from the shooter's own game, and the shooter really is shooting. Layer 5 may not fire, and even when it does the other script may not check. No FiveM resource can reach into another one and cancel its events or stop its loops. Any resource claiming otherwise is claiming something the platform does not offer.

Here is the line that fixes it. It goes at the top of whatever sends the alert, in **that** script:

```lua
-- client realm, in the loop or the handler that decides to alert
if LocalPlayer.state.crimsonArena then return end
```

```lua
-- server realm, in whatever receives it and broadcasts to police
if Player(src).state.crimsonArena then return end
```

That is the same line the startup report prints, with your own `stateBagKey` already filled in, next to the name of the resource that needs it.

**The report cannot then see that you pasted it.** It does not read other people's files, so that row keeps saying `NOT muted` afterwards — what confirms the fix is a round of the arena and a dispatch board that stays quiet. If you would rather the report stopped raising a resource you have handled by hand, name it in `custom.resyncResources`; the row becomes `assumed handled`, worded as an assumption because that is exactly what it is.

#### GTA's own five-star system

`Config.Dispatch.vanillaPolice.enabled` ships **false**, on purpose.

If you run a custom dispatch script you have almost certainly disabled the vanilla wanted system server-wide already, and touching these natives on top of that ranges from pointless to actively harmful — plenty of custom systems drive their own logic off the native wanted level, and pinning it to zero mid-match would fight them for it.

Turn it on only if NPC police still respond to gunfire on your server. It stops NPC cops being dispatched, stops them reacting to the player, and pins the wanted level at zero for the match. Everything it changes is restored on the way out, wanted stars included — walking into an arena is not an amnesty.

---

### Config keys nothing reads yet

None. Every key in `config.lua` is read by something.

Two were removed rather than left sitting here doing nothing:
`Config.Betting.entryFee.hostSetsForEveryone`, because joining always charges
the host's fee and no payout mode weights a share by what a player staked; and
`Config.Dispatch.disableHealthRecharge`, because the multiplier it set cannot
be read back, so the arena could only "restore" it to a guess. Per-player
stakes and a stake-weighted payout are a real feature if you want them, but a
switch that silently does nothing is worse than no switch at all.

This section is kept whether or not it has anything in it: it is the right
place to record the next one, and an operator who has read this file once will
come back looking for it before concluding a setting is broken.

---

## How a round plays out

1. **The lobby.** A player walks up to the NPC and picks the ox_target option, or stands in the marker and presses E. The panel fetches the current snapshot from the server before it takes focus, so it never opens on an empty frame.

2. **Create or join.** The Matches screen lists every open match with its arena, mode, head count, pot and state. Creating one asks for an arena, a mode and — when entry fees are on — the one fee everybody who joins that match pays.

3. **The stake is taken at the door.** Joining takes the entry fee *before* the player is added to the match. A stake that cannot be taken aborts the join and leaves nothing behind: no seat, no place in the join order, nothing to unwind.

4. **Pick a side, pick a loadout.** In a team mode the team picker is shown and any split is legal. In the Loadout screen the player picks up to `weaponSlots` weapons, an ammo amount for each and an armour level. What the panel shows and what the server will allow come from the same file, so the preview and the real thing cannot disagree.

5. **Ready up.** With `autoStartWhenAllReady = true` the match starts on its own once everyone has readied and `minPlayers` is met. Otherwise the host presses start (`onlyHostCanStart`).

6. **Lobby countdown.** `lobbyCountdownSeconds` of a countdown players can still back out of. If someone leaves and the lobby drops below what it needs, the countdown stops and the lobby goes back to waiting — nobody loses their seat.

7. **In.** Everyone is teleported to a spawn point, scattered, frozen, and handed their loadout. Loadouts are **re-resolved at this moment** against the live catalogue, not replayed from what was stored — a weapon an operator switched off since is dropped here rather than granted. This is also the one moment [ammo items](#ammo-types--handing-out-your-own-ammo-items) are handed over, if you have them on.

8. **Live.** After `startCountdownSeconds` the freeze lifts and weapons go live. The pause menu and the multiplayer overlay are blocked for the duration. A once-a-second sweep pushes the scoreboard, runs the round clock and checks the win condition.

9. **Deaths.** The victim's client reports the death and names a killer. That is a **hint**: the server checks the reporter is really in this live match and really alive, and that the claimed killer is somebody in the same match whom the mode would have let land the shot. A claim it cannot verify scores nobody — but the reporter is still eliminated, because that part was never in doubt.

10. **Lives and elimination.** A player with lives left respawns at a fresh point with a fresh loadout after `respawnDelaySeconds`. Out of lives, they are eliminated, ranked, and dropped into the spectator camera.

11. **The end.** Last player or team standing, the score limit, or the clock running out. Two players who die in the same tick are both counted before anything is decided, so a double knockout is a draw rather than a race between two corpses.

12. **Payout.** The pot is settled, the leaderboard is written, side-bets are judged, escrow is cleared, and everyone is teleported to `Config.Lobby.returnCoords` with their own weapons, armour and health back and a results board showing the scoreboard, their placement and what they earned. Any ammo items the arena lent them are taken back on the way out, before anything else about that player is torn down.

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
| The round was **fought** by fewer than `minPlayersToPayOut` | Refunded. This is what stops two friends farming each other. It counts who the round started with, not who is left at the end: otherwise the losing half of a 1v1 could turn a decided match into a refund by walking out of it, and collect the stake that leaving is supposed to forfeit. |
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
| *(none by default)* | client | `Config.UI.command` is `nil`, so no command is registered and the NPC is the only way in. Set it to a name to add one. |
| `/arenaadmin list` | server | admins. Lists every match with its state, head count and pot. |
| `/arenaadmin stop <id>` | server | admins. Aborts one match and refunds everybody. |
| `/arenaadmin wipe` | server | admins. Aborts every match and refunds everybody. |
| `/arenadispatch` | server | admins. Re-runs the police/EMS detection and reprints the startup report. See [Layer 3](#layer-3--the-startup-report-so-you-never-have-to-guess). |

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

- The folder name is not the problem. The panel addresses its calls to `https://<this resource>/<callback>` and gets that name from the game, so it holds under any folder name — including the `-main` suffix a downloaded zip gives you.
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
- If it is the **ammo item** rather than the weapon that is missing, that is a different failure — see [Ammo items are not arriving](#ammo-items-are-not-arriving).
- `Config.Match.stripWeaponsOnEntry = true` (the default) wipes carried weapons on entry. If players are arriving unarmed, check that their chosen loadout resolved to something — a request that resolves to nothing still succeeds and carries only `alwaysGive`.
- Loadouts are re-resolved at match start against the live catalogue. Turn `Config.Debug` on to see what was dropped:

  ```
  [crimson_arena] [debug] dropped 1 loadout entr(ies) for 12 on match m4f2a1: grenadelauncher
  ```

### Ammo items are not arriving

- **Check the switch first.** `Config.Loadouts.ammoItems.enabled` ships `false`, and with it off nothing is asked of any inventory at all. The weapon and its in-game rounds still arrive; the item does not.
- **`ox_inventory` must be started.** If it is not, the console says so in as many words — `ammo items are switched on but ox_inventory is not started` — and nobody is given any.
- **The item name is the usual answer.** The names in the shipped config are placeholders. A name that does not exist on your server produces one console line per attempt, naming the item: `ammo: could not give ammo-rifle-ap x60 to 12 -- check that item exists on this server.` Nothing checks those names at startup, so this line is the only place a typo shows up.
- The same line appears for a **full inventory**, which is not a typo. `allowWeaponWithoutAmmoItem` decides whether that player still fights.
- **Melee, `alwaysGive` weapons and Gun Game rungs never carry an item.** That is by design, not a fault — see [what is not issued an item](#what-is-not-issued-an-item).
- A weapon with `ammoTypes = false`, or one whose ammo `max` is 1 or less, offers no types and so has no item to issue.
- Turn `Config.Debug` on and the grant and the reclaim both print: `ammo: gave ammo-rifle-ap x60 to 12 on match m4f2a1`, then `ammo: reclaimed 41 of 60 item(s) from 12`.

### Ammunition is not coming back

- **A shortfall is usually spent ammunition.** Rounds the player fired cannot be removed, because they are gone. `reclaimed 41 of 60` after a fought match is the expected shape.
- Anything that genuinely will not come out is named: `ammo: <item> x<n> issued to <src> on match <id> could not be taken back (<reason>)`. The reason in brackets is which exit path was running.
- **Check the door.** `Config.Loadouts.inventory.stripOnEntry` is what decides whether a player's own kit is taken and given back. With it off, players keep everything they walked in with *and* everything the arena issued — that is the switch that makes the arena a source of free ammunition, and it exists only for servers that want that.
- `refusing to drop match <id> -- <src> still holds <item> x<n>` means a match record was asked to close with ammunition outstanding and refused. The refusal is the safe outcome — the record stays reachable so a later reclaim can still find it — but it is worth reading as a sign that an exit path did not run.

### The leaderboard is empty

- **Rows are queued, not written immediately.** A match that ended seconds ago appears after the next flush — `Config.Database.flushIntervalMs`, 60 seconds by default — and a flush also runs on resource stop. This is the usual answer.
- The panel caches the board for 30 seconds on top of that. Reopening the panel does not force a fresh read.
- **The database ships off.** With `Config.Database.enabled = false` — the shipped value — the board covers **this server run only** and resets on restart. That is the documented behaviour, not a fault, and it is the first thing to check on a fresh install.
- With it on, the table is created at start by the resource. If it is missing, oxmysql was not connected at that moment — check the oxmysql console lines and restart `crimson_arena` after the database is up, or import `sql/install.sql` by hand.
- A query that cannot be answered falls back to this run's in-memory numbers rather than showing an empty panel, so a board with today's matches and nothing older is a database problem, not an empty table.
- Turn `Config.Debug` on to see flushes: `flushed 4 stat row(s)`.

### Police or EMS are still being called

- **Type `/arenadispatch` first.** It names every police and EMS resource running on your server and says, per resource, whether the arena reaches it. A row reading `NOT muted -- needs the line below` is the answer, and the line it prints is the fix.
- A resource the report does not list is one the catalogue does not know by name. Add the name in `shared/compat/dispatch.lua` and it appears from the next restart.
- `Isolation is off` in the report means `Config.Dispatch.isolation.enabled` is `false`, so every client on the server can see arena gunfire and arena bodies. That is the layer that works without anybody's cooperation — turn it back on.
- **With isolation on, an alert that still arrives almost certainly came from the fighter's own client.** No other machine on the server was sent the fight, so there is nothing else it could have been watching. That narrows it to one file, and the state bag line goes in it.
- If it is only *EMS* being called, the likeliest cause is a script hooking the death **event** rather than polling the death **state**. Layer 2 cannot help with those; the state bag can.
- If a `cancelEvents` entry is not silencing anything, that is the documented behaviour rather than a fault — see [layer 5](#layer-5--cancelling-the-alert-event-and-it-is-best-effort-only). Use the state bag line instead.
- A dispatch script that starts alerting again after *it* restarts has lost its ignore list. Name it in `Config.Dispatch.custom.resyncResources`.

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

# Crimson Arena

A configurable PvP arena for FiveM servers running Qbox. Players walk up to an NPC at the lobby, open a red-and-black panel, pick their weapons, their ammo and their side, and fight it out on grounds you define in `config.lua`. An optional entry fee is held in escrow for the length of the round and paid to the winners when it ends.

**Looking for the inventory rather than the explanation?** [`REFERENCE.md`](REFERENCE.md) lists every feature, command, export and event, and every function in every file with a line on what it is for.

---

## What it does

Everything below is in the shipped code. Where something is off by default, or is a config key that nothing reads yet, it says so.

**Getting in**

- An NPC at `Config.Lobby.ped.coords` with an ox_target option, a ground marker with a keypress, or both — `Config.Lobby.interaction` picks. Ships as `'ped'`.
- A map blip at the lobby. On by default.
- **No slash command exists.** The NPC is the way in, and it is the only way in. There is no setting that adds a second one.

**Staying out of everyone else's way**

- Police and EMS are kept out of the arena — `Config.Dispatch`, built for a custom dispatch script rather than GTA's five-star system, and layered so that most of it works **without you editing either of those scripts**. Every match is fought in its own routing bucket, so no other player's client is ever sent arena gunfire, arena bodies or arena entities, and a dispatch or ambulance script running on one has nothing to detect. An arena death is put back on its feet in the same instant, so a medical script's polling loop never catches a casualty. At start the console prints which police and EMS resources you are really running and what the arena can do about each one. What is left over is the alert your own script sends about its own player, and that is one line in it. See [Keeping police and EMS out of the arena](#keeping-police-and-ems-out-of-the-arena).

**The panel**

- Vanilla HTML/CSS/JS, no framework and no build step. Five screens — Matches, Lobby, Loadout, Bets, Leaderboard — plus a live scoreboard overlay during a round (`Config.UI.showMatchHud`).
- Every colour comes from `Config.UI.theme` at runtime. Recolouring config recolours the panel; nothing is hard-coded.
- `Config.UI.sounds` switches the panel's own feedback tones on and off. They are short notes synthesised in the page rather than audio files, and the first panel of a session can be silent until the page has seen a click of its own — a browser will not start audio off the keypress that opened it.

**Weapons and ammo**

- The weapon list is `Config.Loadouts.weapons`, and it lives in **`config.weapons.lua`** rather than `config.lua` — a thousand lines of weapon blocks that everybody editing a timer or a payout used to scroll past. Delete an entry or set `enabled = false` and it is gone from the arena — the server refuses it even when a modified client asks for it by name.
- **96 entries ship and 77 of them are enabled**, in six categories: 25 sidearm, 24 automatic, 9 shotgun, 7 precision, 13 heavy and 18 melee. **All eighteen melee weapons are on.** What ships off is the whole `heavy` category — launchers, the minigun, explosives — plus six sidearms.
- **Twelve MK II weapons ship and every one of them is enabled**, Heavy Sniper MK2 included. Each carries its own `ammoTypes` list naming the item that weapon fires.
- Each weapon carries its own ammo block: `options` is what the picker offers, `max` is the ceiling the server clamps to. A weapon with no `options` (melee) offers no ammo choice and is handed out at `default` — with `max` left as the only limit on the wire for it, so every shipped melee entry sets the two to the same number.
- **Ammo items ship switched ON** (`Config.Loadouts.ammoItems.enabled = true`), with a real item name on every weapon — `ammo-9`, `ammo-shotgun`, `ammo-heavysniper` — read out of that weapon's own `ammoname` in ox_inventory. The round follows the weapon; the player is never asked to choose one. See [Ammo types](#ammo-types--handing-out-your-own-ammo-items).
- **The amount is a total**, split between the magazine and the pocket: 60 rounds on a Pistol is 30 loaded and 30 as items.
- `weaponSlots` caps how many **shootable** weapons one player may take — 2 as shipped. **Melee has its own allowance**, `meleeSlots`, also 2, so a player carries two firearms *and* two melee weapons. Nothing is added on top: a player carries what they picked and nothing else.
- **Full health and a full plate on every life, always.** That is a rule of the arena and not a setting — there is no `Config.Loadouts.armor` block and no `health` key any more, and neither a config edit nor a crafted client payload reaches it. Both realms read the same two numbers from `Arena.StartingVitals` (200 and 100), and what the client applies is a *floor*, so even a stale loadout starts you on a full plate.
- **What you *can* pick is the spare kit you carry in.** `Config.Loadouts.supplies` ships on, with body armour (max 4, default 1) and bandages (max 6, default 2) and a shared ceiling of 8 items across everything. They are real `ox_inventory` items, handed over at the start of the round and taken back on the way out with the rest of the arena's kit — and taken back *against what the player still holds*, so somebody who used two of three bandages does not keep the third.
- **The host picks the loadout, not the player.** `Config.Loadouts.chooser` ships as `'host'`: the host chooses once and everyone in that match fights with it. The server *refuses* a loadout request from anybody else rather than merely greying the panel out. Set it to `'player'` for everyone to pick their own.

**Teams**

- Players pick their own side (`Config.Teams.allowChoose`).
- **Uneven teams are legal by default** (`allowUnequal = true`). 7v1 starts. The pot splits evenly across the winning team, so stacking a side dilutes what winning on it is worth rather than guaranteeing it.
- Four teams ship; two are enabled. Enabling a third needs no code change — give it spawn points in each arena's `teamSpawns` or it falls back to the shared list.
- `Config.Teams.friendlyFire` does **not** block the damage. It decides whether a teammate's kill is *credited*: with it off the victim still dies and still spends a life, but nobody scores.
- `showTeamBlips` and `showEnemyBlips` put blips on the living fighters of your own match, tinted with the team's `blipColor`. They ship on and off respectively. A free-for-all has no teammates, so `showEnemyBlips` alone decides there.

**Matches**

- `Config.Match.maxPlayers = 0` — any number of players in one match. Several matches can run side by side (`maxConcurrentMatches = 0` for no ceiling).
- Modes: **Free For All** and **Team Deathmatch**.
- Win conditions: `last_standing` (default), `most_kills`, `score_limit`. A tie is a draw and refunds rather than picking one of two equal scores.
- Lives, respawn delay, a round clock (`roundTimeSeconds = 0` for none), a lobby countdown players can still back out of, and a frozen start countdown.
- Per-arena boundary sphere: a warning, then damage per tick until the player comes back. `boundary.enabled = false` for an open arena.
- Optional per-arena weather and time overrides. Both `nil` by default.
- Eliminated players get an orbiting spectator camera and can cycle between the fighters (`spectateOnElimination`).
- Players get back the weapons, ammo, armour and health they walked in with (`Config.Match.restoreLoadoutOnExit`, on by default) on every path out of the arena — round end, an aborted match, leaving or disconnecting mid-round, and a resource restart. Health comes back whatever that setting says: nobody leaves the arena as a corpse.

**Betting**

- One switch — `Config.Betting.enabled` — hides every bet control and makes the server reject any bet that arrives anyway.
- Entry fees are held in escrow, not tracked against a balance. Payout is `winner_takes_all` (default) or `per_kill`, with an optional house cut. Anything else is read as `winner_takes_all`, so a typo cannot swallow a pot.
- Spectator side-bets on a team or a fighter, on by default. **Parimutuel as shipped**: winners split the pool in proportion to what they staked, funded by the losing bets and never by the server. Fixed odds at `oddsMultiplier` is the alternative, per crowd, in `Config.Betting.betPayout`.
- **One pot as shipped, not two.** `betPayout.sharedPool` puts the fighters' and the spectators' bets in the same pool, and `betPayout.includeEntryPot` puts the entry fees in it as well — a fighter's fee is a stake on their own side. So a bystander's money *does* reach the winner, on purpose: it is what makes a small arena's pool worth betting into. Turn either off to keep the crowds' money apart.
- **A pool with nobody on the other side is handed back, not won.** A share of a pool that contains only your own stake is exactly your own stake, so the arena returns it and says so rather than announcing a win that pays nothing.
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
| [ox_target](https://github.com/overextended/ox_target) | the option on the lobby NPC | no NPC is spawned and the console says so. Set `Config.Lobby.interaction` to `'marker'` or `'both'` if you want the ground marker instead |
| [ox_inventory](https://github.com/overextended/ox_inventory) | **the arena weapons themselves**, [their ammo items](#ammo-types--handing-out-your-own-ammo-items), and the stash that holds a player's own kit during a match | nothing is issued at all — weapons are items, so fighters would stand in the round with only what they walked in carrying, and nobody's own kit is stashed |
| [oxmysql](https://github.com/overextended/oxmysql) | the all-time leaderboard, and only when `Config.Database.enabled` is on — it ships **off** | the leaderboard covers the current server run |

None of those three is named in the manifest and none is imported by it, so with the shipped settings this resource starts on a server that has no database resource, no target script and no inventory script at all. Turn a feature on and the resource asks for what it needs at that moment; if the answer is no, it says so in the console once and carries on.

## Installing

Drag, drop, one line in `server.cfg`, start.

> **Updating an existing install: copy the whole folder, not the files you recognise.**
> `config.weapons.lua` is a separate file from `config.lua` — the weapon catalogue used
> to live inside `config.lua` and was split out. A server updated by replacing only the
> files it already had ends up with no catalogue at all, and the symptom is the panel
> saying *No weapons are enabled on this server*. The console says which file is
> missing on every start, so check it if you see that.

1. Drop this `Crimson-Arena` folder into your resources directory. It arrives named the way it should be named there, so there is nothing to rename — but **any folder name works** if you would rather use another: `crimson_arena`, `[custom]/whatever`, or the `-main` suffix a zip leaves behind. The panel asks the game what it was installed as rather than assuming.
2. Add one line to `server.cfg`, below wherever you already start qbx_core:

   ```cfg
   ensure Crimson-Arena
   ```

   Use whatever the folder is actually called. Nothing else needs adding, and there is no order to get right beyond being after qbx_core.

3. **You do not have to import any SQL.** `Config.Database.enabled` ships `false`, and nothing is created or queried while it is. Turn it on and `crimson_arena_stats` is created on first start; `sql/install.sql` holds the identical statement for the case where your database user cannot `CREATE TABLE` at runtime, which is a reasonable way to run a production server.
4. **Optional, and the arena works before you do any of it.** Edit `config.lua`: move `Config.Lobby.ped.coords` and `Config.Lobby.returnCoords` somewhere that suits your map, and check the two shipped arenas suit you.

   They are deliberately different animals. **Trailer Park** (`trailerpark`) is a real place on the map — it has its own trailers and fences to fight around, so it spawns nothing of its own. **The Skydome** (`skydome`) is built rather than found: a floor of props tiled into a disc at 1201 m over open water, walled in by a double-stacked ring of shipping containers so nobody walks off the edge, with cover inside it, spawned per match and deleted when it ends, and it grows with the roster. Nothing is built over the top — it is a wall, not a box. Coordinates are a starting point rather than a finished map.
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

`config.lua` and `config.weapons.lua` are the two files an operator edits — settings in the first, the weapon catalogue in the second. Each snippet below is lifted from one of them.

### Adding a weapon and its ammo options

Add an entry to `Config.Loadouts.weapons`, in `config.weapons.lua`. `key` is what the panel and the wire use and must be unique; `weapon` is the real GTA weapon name and is what is actually given.

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

**Whether an off-list amount is allowed depends on `Config.Loadouts.allowCustomAmmo`, which ships `true`.** On, a player may type an exact figure and anything in `[0, max]` is granted — asking for 121 gets 121. Off, `options` is the whole list of legal answers and an off-list request is **refused, not rounded**: asking for 121 gets you `default`, not 120. Rounding to the nearest legal value would let a modified client walk a number up past a preset by asking for one just above it.

`max` is the hard ceiling either way, clamped server-side no matter what arrives on the wire.

A weapon with no choice to make sets `options = nil`. The panel offers no chips for it — it prints the count as fixed instead — and the player is handed `default`:

```lua
ammo = { default = 1, options = nil, max = 1 },
```

With no list to check a request against, `max` is the only limit that weapon has left on the wire: a modified client asking for a number between `default` and `max` is given it, because that is what `max` means everywhere else in the file. **Set `max` equal to `default` for a weapon whose count is meant to be fixed** — all eighteen melee entries ship that way, which is why nothing on the shipped catalogue has any headroom to ask into. Leave the two apart only when free-form ammo up to the ceiling is what you meant.

Removing a weapon is `enabled = false`. That genuinely removes it — it does not merely hide a button.

### Ammo types — handing out your own ammo items

If you run an ammo script where a round is an inventory item — `ammo-rifle`, `ammo-9`, a box of armour-piercing — this is how the arena hands one out and, more importantly, how it takes it back.

There are two halves and they are independent. A type may carry an **item**, which is yours; it may carry a **component**, which is GTA's; it may carry both, or neither. The item half is what this section is mostly about. The component half is [further down](#mk-ii-magazines-are-components-not-items).

#### It ships on, with the round each weapon actually takes

```lua
ammoItems = {
    enabled = true,
    ...
}
```

Every firearm in `Config.Loadouts.weapons` carries its **own** single-entry `ammoTypes` list naming the item that weapon fires — `ammo-9` on the pistols, `ammo-heavysniper` on the heavy sniper, `ammo-shotgun` on the shotguns — read out of that weapon's `ammoname` in ox_inventory. Pick the weapon and the right round follows it; there is nothing to correlate by hand.

**The player is never asked which round they want**, and the panel does not offer a picker for a weapon with one type. The round comes from the weapon, and asking for a different one is ignored rather than refused — a pistol asking for .50 BMG gets 9mm.

If your server names its ammo items differently, the `item` field on each weapon's `ammoTypes` line is the one to edit. Handing out an item name that does not exist is a **silent nothing** in the player's inventory and one console line for you:

```
[crimson_arena] ammo: could not give ammo-rifle x60 to 12 -- check that item exists on this server.
```

Nothing validates those names at startup — the config validator cannot know what items your inventory has — so that line is the only place a typo shows up. Grep for it after changing any of them.

#### The amount is a total, split between the gun and the pocket

A player picking 60 rounds gets **60 rounds**: one magazine loaded in the weapon and the remainder as items they can see and reload from.

```
Pick: Pistol, 60 rounds
  WEAPON_PISTOL x1   magazine = 30
  ammo-9        x30
```

Where the split falls is the weapon's own `magazine` if it names one, otherwise **the smallest amount that weapon's own `ammo.options` offers** — the operator's own idea of a small quantity of that round, already written beside the weapon. Every firearm shipped has one (30 on most, 60 on the rifles, 20 on the shotguns, 10 on the heavy sniper, 4 on the launchers), so nothing needs adding to use it. `Config.Loadouts.ammoItems.defaultMagazine` catches a weapon with no options list at all.

The magazine is never more than the pick: choosing 30 on a 30/60/120 weapon arrives as 30 loaded and nothing spare, because thirty rounds is thirty rounds.

> **This was wrong until recently, and badly.** The magazine was filled with the whole pick *and* the same amount was handed over again as items — 60 chosen, 60 in the gun, 60 in the pocket, **120 carried**, on every weapon of every round. Two loops each doing their own job correctly, neither aware the other had already issued the lot, each with its own passing test. The total was the thing nobody asserted.

One prerequisite: **`ox_inventory` must be running.** It is the only inventory this file knows how to talk to, and it is looked up fresh on every call rather than cached, so restarting your inventory resource does not leave the arena holding a dead handle. If ammo items are on and `ox_inventory` is not started, nobody is given anything and the console says so once per attempt:

```
[crimson_arena] ammo items are switched on but ox_inventory is not started -- nobody is being given any.
```

**Nothing checks your item names at startup.** The config validator checks weapon keys, ammo ceilings, spawns, teams and betting numbers; it does not and cannot know what items exist in your inventory. A wrong name surfaces on the first match that asks for it, in the server console, naming the item:

```
[crimson_arena] ammo: could not give ammo-rifle x60 to 12 -- check that item exists on this server.
```

That is the line to grep for after you first switch this on. Read it as "this name is wrong, or that player's inventory is full".

#### Set the list once, override where you need to

`Config.Loadouts.defaultAmmoTypes` is the fallback list, inherited by any weapon that does not name its own. Every firearm shipped names its own, so editing this alone changes nothing for them:

```lua
defaultAmmoTypes = {
    { key = 'standard', label = '5.56x45', item = 'ammo-rifle' },
}
```

That shared list is the **fallback only**. Every shipped firearm overrides it with its own single entry, so the list above is what a weapon you add later inherits if you give it no `ammoTypes` of its own.

`key` is what the panel and the wire use and must be unique in a list. `label` is what the player reads. `item` is the one you must edit. `enabled = false` hides an entry without deleting it.

Three levers, in order of how often you will want them:

| You want | Do this |
|---|---|
| The same types everywhere | Edit `defaultAmmoTypes`. Nothing else. |
| Different item names on one weapon — a pistol round and a rifle round are separate items | Give that weapon its own `ammoTypes = { ... }` list. It replaces the shared one for that weapon, it does not add to it. |
| No types at all on one weapon | `ammoTypes = false` on that weapon. An explicit `false` beats the shared default. |

**Melee is excluded automatically.** A weapon whose ammo `max` is 1 or less never inherits the shared list, because a weapon that carries one "round" is not carrying ammunition, it is carrying a bat. You do not have to write `ammoTypes = false` on the eighteen melee entries, and you should not: the rule is in the code, so a melee weapon you add later is excluded too.

**Which type a player gets when they express no preference** is `defaultAmmoType` — set per weapon, falling back to `Config.Loadouts.defaultAmmoType` for the whole list, falling back to the first enabled entry. That matters more than it sounds: it is what is issued for anything that never went through a player's choice at all.

An unknown or disabled type key arriving on the wire is **refused back to the default, not guessed at** — the same posture as an off-list ammo count. So shortening a list genuinely removes that round from the arena rather than merely hiding it.

#### `roundsPerItem`, when one item is a box

```lua
roundsPerItem = 1,
```

With ox_inventory's usual per-round ammo items this is 1: a player who picks 60 rounds on a weapon with a 30-round magazine is handed 30 items and the other 30 are already in the gun. If one item on your server is a **box of 30**, put 30 here and they are handed 1.

It applies to the **spare** rounds, not the pick — the magazine is rounds, not items, and is never divided by this.

The division **rounds up**, on purpose. 61 spare rounds at 30 per box is three boxes, not two — rounding down would hand somebody less than they asked for and leave them wondering what happened. The reclaim takes back the same number of items that were issued, so the rounding is symmetric and nobody is short-changed or quietly enriched by it.

A value of 0 or below is treated as 1 rather than dividing by zero.

#### If the item will not go in

```lua
allowWeaponWithoutAmmoItem = true,
```

An `AddItem` can fail for reasons that have nothing to do with your config — most often a full inventory. This decides what happens then:

- **`true` (the default, and the friendlier one)** — the player fights with the magazine and no reloads. The failure is named in the console for you.
- **`false`** — that **weapon** is taken back off them. They keep their place in the round and everything else they picked; what goes is the one gun they cannot reload. It does not eject the player: unwinding a dispatch flag, a routing bucket and a stash mid-placement is how people get stranded.

A weapon picked at or under one magazine has no spare rounds to issue, so there is no item to refuse and neither branch is reached — which is right, because that gun is already carrying every round the player asked for.

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
stripOnEntry = true,
```

The switch exists, it defaults to on, and turning it off makes the arena a source of free ammunition. It is there only for servers that genuinely want that. If you are not sure, you do not.

Three things worth knowing before you watch it run:

**A round the player already fired cannot come back, and that is expected.** They were given it to shoot. The reclaim asks the inventory for what it issued and gets what is still there; the shortfall is spent ammunition, not a fault. Do not read a partial reclaim as a bug.

**Anything that will not come out is named in the console rather than written off.** A silent teardown that took nothing back looks exactly like a clean one, so it is never allowed to look clean:

```
[crimson_arena] door: 3 item(s) of 12's own kit could not be returned -- they stay in stash arena_ABC123.
```

**Reclaiming twice takes nothing twice.** Each record is marked as it is returned, and the exit paths overlap by design — a disconnect mid-round routes through the ordinary exit *and* is caught again by the disconnect handler. The second pass is a no-op. That is deliberate: two guards that both fire are safe, one guard that misses is an ammo printer.

**The exit clears the whole inventory and gives the stash back**, rather than removing issued items one by one, so nothing the arena produced can leave with anybody and a player's own kit is what returns. Test that deliberately anyway — some inventory setups tie a weapon's in-game round count to the item backing it. Whether the two reconcile on your build is a question only your server can answer.

Turn `Config.Debug` on and the door says what it did on each exit:

```
[crimson_arena] [debug] door: 12 left (match ended), kit returned
```

#### What is *not* issued an item

Worth knowing before you go looking for a bug that is not there. Items are handed over **once**, at the moment a player is placed in the arena, for the weapons in the loadout they chose. Specifically:

- **Respawns do not issue more.** A player who dies and comes back still has their weapon, because it is an `ox_inventory` item that was never taken off them — nothing re-hands it and no second item is put in their inventory. One loadout's worth per player per match is the whole of what the arena lends.

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
| `component` only | The magazine is attached to the weapon on entry. **This needs no inventory and works with `ammoItems.enabled = false`.** The mechanism is live in code, but **nothing in the shipped config uses it** — `COMPONENT_` does not appear in the catalogue at all. |
| `item` only | Your ammo script's item is handed over and reclaimed. Works on any weapon that takes ammunition. |
| both | Both. The magazine is attached *and* the item is issued. |
| neither | The type still resolves and is still named in the loadout, and nothing is handed over. |

The component is appended to a **copy** of that weapon's `components` list, never to the config table itself — one player's chosen clip cannot leak into the next player's loadout.

Component names are only meaningful on MK II weapons. Adding a `component` to a plain Assault Rifle does nothing useful, because there is no magazine for it to attach.

**The shipped config now does the opposite of what this section was written to warn about.** Every weapon in the catalogue — MK II or not — carries its own `ammoTypes` list with a real `item` filled in and **no `component` at all**. So editing `defaultAmmoTypes` changes nothing for any of them, not just for twelve; and no MK II weapon arrives with a special magazine attached unless you add one. That is exactly right for a server with no ammo script. A per-weapon list *replaces* the shared one, so editing `Config.Loadouts.defaultAmmoTypes` reaches only a weapon that has no `ammoTypes` of its own — and every shipped weapon has one.

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

### The arena grows with the match

Twenty fighters in a circle sized for six is a different game. `minSeparation`
stops being satisfiable, and the placement used to quietly settle for less —
so a stated ten metres was never the ten metres anybody got, and the first
thing twenty players saw was each other.

An arena can say it should grow instead:

```lua
scale = {
    enabled = true,
    baseline  = 6,     -- the roster the radii below are written for
    perPlayer = 1.6,   -- metres of spawn radius added per fighter above it
    maxGrowth = 2.0,   -- never bigger than twice the configured size
},
```

**One number scales all of it** — the spawn area, the floor, the boundary, and
where the cover sits. That is the point: the relationships between them are
the arena's design, and two of them are what keep people alive (spawns inside
the floor, floor inside the boundary). Scaling any one on its own breaks one
of those, silently.

The server works the factor out once, when the round starts, from the roster
it is starting with — and sends it to every client, because the client builds
the floor and cannot see a roster. It is not recomputed later: a factor
re-derived from a roster that has since lost a player would shrink the arena
under the people standing in it.

The shipped `skydome` uses it, so six fighters get the 35 m circle in config
and twenty get a 57 m one on a floor to match. Every roster size from four to
thirty-two lands the full stated separation, checked across sixty random
seeds for each of seven roster sizes — four hundred and twenty rosters — in
`tests/skyarena_spec.lua`.

Leave the block out and the arena stays the size you configured. Both
shipped arenas do scale, to different ceilings: the skydome up to 2.0x
because it is built from nothing, the trailer park only to 1.35x because it
is a real place with a fence and a highway around it.

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
| 6 | Withdrawing the call after it has been filed | No — needs your dispatch script's own clear-a-call export, which is named in config. |

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
- **And their body is parked at the arena, which is the other half of that.** The bucket decides who a player *could* be sent; with OneSync on, what they *are* sent is culled around their body. A viewer standing at the lobby is never sent the fighters however long the camera waits, so watching a match you are not in showed an empty field and then reported nobody left to watch — while an eliminated fighter, already stood in the arena, could watch the same round perfectly. `client/spectate.lua` moves the (invisible, frozen, collisionless) body to the arena for the duration and puts it back afterwards, and the keep-out fence exempts the arena somebody is watching so the barrier loop does not shove them straight back out.
- **Everybody is returned on `onResourceStop`, first, before anything else in the shutdown.** A bucket lives in the server, not in this resource: stopping `crimson_arena` does not empty one. A player left behind in an arena instance is alone in an invisible copy of the map, cannot fix it themselves, and does not get it cleared by reconnecting.
- **A bucket is a network boundary, not a permissions boundary.** Server-side code still sees every player normally — a dispatch script's *server* half looping over players finds an arena player exactly as it always did. That is what layer 4 is for.
- **Proximity voice and anything else that follows client replication follows the bucket too.** In practice a fighter hears their match and nobody outside it. Check yours if that matters to you.

**And the limit, which is the reason the rest of this section exists:** a bucket hides the fight from every *other* machine on the server. It cannot hide an arena player's gunfire from **their own** client. See [the one limit](#the-one-limit-nothing-here-gets-past).

#### Layer 2 — an arena death is undone in the same instant

```lua
clearDeadStateImmediately = true,
```

Most medical scripts spot a casualty by watching whether a player is dead, on a loop running somewhere between twice a second and once a second. The stock `baseevents` resource finds one the same way, which is where a great many "player died" handlers on a server ultimately come from.

With `clearDeadStateImmediately`, an arena death is reported to the server and the body is put back on its feet in the same instant — frozen, invisible and untouchable until the server says whether they respawn or are out. In practice that loop never has a dead player to find, and no ambulance is ever paged. The player sees no difference: they are held in place either way, waiting on the server. It also makes respawning feel sharper, which is why it is on even for servers with no medical script at all.

**The honest limit:** a script that hooks the death *event* rather than polling the death *state* still fires, because the player really did die. Layer 4 is the answer for those. This is not a substitute for it.

#### Layer 3 — the startup report, so you never have to guess

Every other layer is either invisible when it works or needs something from you. This one exists to tell you which.

Five seconds after the resource starts — five, because resource start order is not guaranteed and a dispatch script listed below this one in `server.cfg` has not started yet at zero — the arena looks up every police and EMS resource name it knows about, sees which are running on **your** server, and prints one short block naming each one and what it can do about it.

Nothing wired up yet, with this server's dispatch and the Qbox ambulance job running:

```
[crimson_arena] dispatch compat: 2 police/EMS resource(s) running.
[crimson_arena]   sc-dispatch          police+EMS  NOT muted -- needs the line below
[crimson_arena]   qbx_ambulancejob     EMS         NOT muted -- needs the line below
[crimson_arena] Isolation is on: no OTHER player's client can see the fight. An arena player's own client still can -- that is what the line below is for.
[crimson_arena]   Paste at the top of whatever sends the alert, in that script:
[crimson_arena]       if Player(src).state.crimsonArena then return end        -- server realm
[crimson_arena]       if LocalPlayer.state.crimsonArena then return end        -- client realm
[crimson_arena] Hooks configured: entry/exit events. /arenadispatch re-runs this report.
```

The same server once the dispatch board is handled through its own ignore export:

```
[crimson_arena] dispatch compat: 2 police/EMS resource(s) running.
[crimson_arena]   sc-dispatch          police+EMS  muted automatically -- disableExports calls exports.sc-dispatch:SetIgnoredPlayer
[crimson_arena]   qbx_ambulancejob     EMS         NOT muted -- needs the line below
[crimson_arena] Isolation is on: no OTHER player's client can see the fight. An arena player's own client still can, and nothing here is confirmed wired -- that is what the line below is for.
[crimson_arena]   Paste at the top of whatever sends the alert, in that script:
[crimson_arena]       if Player(src).state.crimsonArena then return end        -- server realm
[crimson_arena]       if LocalPlayer.state.crimsonArena then return end        -- client realm
[crimson_arena] Hooks configured: 1 disableExport(s). /arenadispatch re-runs this report.
```

One row is handled and one is not, so the report keeps the caveat and keeps
printing the line to paste: a single uncovered resource is enough for it to
stop claiming the setup is wired.

Reading it:

| Row says | It means |
|---|---|
| `muted automatically` | The arena really calls something on that resource on entry and exit. Nothing more to do. |
| `NOT muted -- needs the line below` | Nothing in the arena reaches it. Paste the line it prints. |
| `Isolation is off` | Layer 1 is switched off, so every client on the server can see arena gunfire and arena bodies. |
| `Isolation is CONFIGURED ON BUT NOT IN FORCE` | You asked for it and the server is not doing it. The report says which of the two it is: OneSync off, or a routing bucket the server accepted and then ignored. Run `/arenaisolation` for the readings. |

`/arenadispatch` runs the whole detection again, live, and prints the same block — after installing a dispatch script, or after pasting the line it asked for, without a restart. It is gated on `Config.Permissions.adminGroups`, and the server console always qualifies. An admin who runs it in-game has no console to read, so they get the block as one notification as well.

**Nothing in the catalogue ships with a mute call, deliberately.** A third-party script's export names cannot be verified from inside this resource, and a guessed export name is the worst outcome available: it detects as present, reports itself as handled, and silently does nothing — strictly worse than admitting the resource is unhandled. Detection is what drives the report, and the report is the point.

Detected by name today:

| Kind | Resources |
|---|---|
| Dispatch boards (`police+EMS`) | `sc-dispatch` |
| Police (`police`) | `sc-police`, `qbx_policejob`, `qbx_police` |
| EMS (`EMS`) | `sc-ambulance`, `qbx_ambulancejob`, `qbx_medical` |

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

**Each name is registered for the network as well as handled.** FXServer delivers a client-raised event only to a resource that has called `RegisterNetEvent` for that name, and gunfire and deaths are raised with `TriggerServerEvent` from the player's own client — so without it this whole layer never ran for the alerts that matter. Safe-for-net is per resource: it marks the name callable into *this* resource's handlers and changes nothing about the script that owns the event.

The list ships pointed at the six events `sc-dispatch` and `sc-ambulance` really raise — `sc-dispatch:server:ShotsFired`, `hospital:server:EMSDownAlert`, `hospital:server:ambulanceAlert`, `mydispatch:requestEMS`, and `sc-dispatch:server:PlayerDown` and `sc-dispatch:server:PlayerDead`, which sc-dispatch's own client raises off the QB down metadata without anybody pressing a key. It previously named `sc-dispatch:server:AddNotification` and `sc-dispatch:AddNotification`, neither of which exists in either resource: `AddNotification` is an **export**, and nothing can register a handler on an export call. Those two entries never fired once, so this whole layer was listening to silence while every round paged police and EMS. The startup report counts what you put in the list and labels it `(best effort)` there too.

#### Layer 6 — withdrawing the alert after it is created

**This is the layer that actually removes an `sc-dispatch` call**, and it exists because layer 5 provably cannot. Per Cfx's own documentation `CancelEvent()` does not stop another resource's handler from running, and `sc-dispatch` never calls `WasEventCanceled()` — so every event named in layer 5 still creates its call.

Most dispatch scripts expose a *clear this call* export and file each call under an id built from facts the arena can see. Name the export and the id shape, and an arena alert is withdrawn the moment it is created:

```lua
retract = {
    resource = 'sc-dispatch',
    export = 'ClearNotification',
    delayMs = 250,
    clockSlack = 1,
    idTemplates = {
        ['sc-dispatch:server:ShotsFired'] = 'shots_%d_%d',
        ['hospital:server:EMSDownAlert'] = 'emsdown_%d_%d',
    },
},
```

The first `%d` is the player's server id, the second the unix timestamp — the order both `sc-dispatch` and `sc-ambulance` build them in.

**Why it is delayed.** Both handlers hang off the same event and nothing decides which runs first. Clearing a call the other handler has not inserted yet clears nothing, so `delayMs` pushes the withdrawal past that handler's own database work. Raise it if calls still linger; every millisecond is time the alert is live on an officer's screen.

**Why it cannot reach somebody else's call.** Every id it builds carries the arena player's own server id in the middle. `clockSlack` widens the *timestamp* — closing the gap when the two handlers straddle a one-second boundary — never the player.

**The honest limit.** The alert is created before it is withdrawn. An officer on duty in that moment still hears the notification sound and may see the entry blink in and out. What this stops is the call *persisting* — units driving to an arena, a blip sitting on the map for the length of `AutoClearTime`, a round's worth of 10-71s stacking up in the MDT. Stopping the sound as well takes the one line below, inside the sending script.

Unlike layer 5, this **is** counted as wired up in the startup report, because it does not depend on the other resource agreeing to anything. Set `resource` to nil to switch it off.

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

**The report cannot then see that you pasted it.** It does not read other people's files, so that row keeps saying `NOT muted` afterwards — what confirms the fix is a round of the arena and a dispatch board that stays quiet.

#### GTA's own five-star system

**The arena does not touch it.** Entering and leaving a match reaches no game native at all, which is why there is nothing to hand back on the way out.

A server running a custom dispatch script has disabled the vanilla wanted system server-wide already, and touching those natives on top of that ranges from pointless to actively harmful — plenty of custom systems drive their own logic off the native wanted level, and pinning it to zero mid-match would fight them for it. If NPC police still respond to gunfire on your server, that is a setting on your server rather than something the arena can turn off for one round.

---

### Config keys nothing reads yet

None. Every key in `config.lua` is read by something.

A key that silently does nothing is worse than no key at all, so anything
that stops being read is removed rather than left here. Per-player stakes and
a stake-weighted payout are a real feature if you want them; a switch that
pretends to offer them is not.

This section is kept whether or not it has anything in it: it is the right
place to record the next one, and an operator who has read this file once will
come back looking for it before concluding a setting is broken.

### Getting back up after a death

**There is nothing to configure for this, and nothing to grant.** The arena
stands its own dead back up itself, in code. It knocked the player down, so
putting them back on their feet is not a privileged act and it does not ask
the server for permission to do it.

That happens on a mid-match respawn and again when the match ends, so nobody
walks out of the arena still on the floor. It works on a fresh install with an
untouched `config.lua`.

#### Telling your medical script

A medical or ambulance resource keeps its **own** record of who is dead, and
nothing about resurrecting a ped reaches it — so a player can be up and
walking while that script still has them listed as a casualty, and does
whatever it does to a casualty.

**You do not configure that handoff, and there is nothing in `config.lua` to
fill in.** The catalogue in `shared/compat/dispatch.lua` carries the revive
event each medical script listens for, read out of that script's own source,
and the arena fires it for whichever of them is really running on your box.
The startup report names the event it will send:

```
revive: 1 detected medical script(s) are told to revive a player directly -- hospital:client:Revive.
```

If nothing is detected, the report says so plainly and points at the one place
to fix it:

```
revive: NOTHING IS TELLING YOUR MEDICAL SCRIPT. No script this catalogue knows is
  running, so a player who dies in a match walks out of the arena
  still dead as far as that script is concerned.
```

The fix is a line in that catalogue naming your script and the event it
listens for — read out of its own source, never guessed. A name that is close
but not right looks wired up and calls nothing, which is worse than no name.

#### Why it does not run `/revive`

A command run from a resource is run **by** that resource, and an admin
command checks whether its caller is allowed — a resource is not an admin, so
the command is refused. A refused command is not an error, it is a command
that did nothing, so a console could honestly report running it while the
player stayed on the floor.

Granting the permission does not fix it either, because a resource may not
grant itself permissions — correctly, since a server where it could is a
server with no permissions at all. Both doors are shut, so the arena does not
knock on them: it writes no ace, joins no group, runs no command, and has no
setting to make it try.

---

---

## How a round plays out

1. **The lobby.** A player walks up to the NPC and picks the ox_target option, or stands in the marker and presses E. The panel fetches the current snapshot from the server before it takes focus, so it never opens on an empty frame.

2. **Create or join.** The Matches screen lists every open match with its arena, mode, head count, pot and state. Creating one asks for an arena, a mode and — when entry fees are on — the one fee everybody who joins that match pays.

3. **The stake is taken at the door.** Joining takes the entry fee *before* the player is added to the match. A stake that cannot be taken aborts the join and leaves nothing behind: no seat, no place in the join order, nothing to unwind.

4. **Pick a side, pick a loadout.** In a team mode the team picker is shown and any split is legal. In the Loadout screen up to `weaponSlots` shootable weapons and `meleeSlots` melee weapons are chosen, with an ammo amount for each. **As shipped that choice is the host's**: `Config.Loadouts.chooser` is `'host'`, so everyone fights with the host's kit and the others are shown what they will be carrying rather than a picker they cannot use. Armour is not part of the choice at all — everyone starts every life on full health and a full plate, by rule. What you may choose is the **spare kit you carry in**: extra plates and bandages, up to a shared ceiling. What the panel shows and what the server will allow come from the same file, so the preview and the real thing cannot disagree.

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

**The account a player picks is the only one tried.** Cash or bank, for the entry fee and for bets. Falling back to the other would spend a pocket they deliberately left alone, which is the same class of mistake as clamping a number somebody typed.

That distinction has three cases, not two, and collapsing the last two was a real hole:

- **Nothing sent** — no preference. Falls back to the operator's order, and must, or a panel that predates the choice cannot pay at all.
- **A name that is not one of that player's accounts** — junk from a stale panel or a crafted payload. Nothing was really chosen, so it is treated as no preference too. Refusing a player who can plainly pay, because something sent a word nobody recognises, helps nobody.
- **A real account of theirs that this server does not debit** — a choice that *cannot be honoured*, and the one this used to get wrong. A player picks cash; the operator later removes cash from `Config.Betting.accounts`; the old code could not tell that from a typo and quietly took the money out of the bank instead. Now nothing moves, from either account, and a console line says why.

**Two pools, or one, and the shipped answer is one.** The entry-fee pot is what the fighters are playing for, and `maxPot` caps it; side-bets live in their own table. Whether those stay apart is `Config.Betting.betPayout`, and as shipped they do not: `sharedPool = true` pools the fighters' and the spectators' bets together, and `includeEntryPot = true` folds each fighter's entry fee in as a stake on their own side. There is then **one pot and one set of winners**, and a bystander's stake does reach the winner. That is the point of it — an arena with three spectators and no shared pool is an arena nobody bothers betting in — but it is the opposite of what separate pools mean, so set both to `false` if what you wanted was a fighters' pot a bystander cannot touch.

**A pool is the bettors' money, so the house never keeps it.** Fixed odds has a counterparty and a loser's stake stays with the server. A pool has none: a losing stake is paid to whoever backed the winner, and where nobody did — nobody backed the winning side, or nobody bet against a lone self-backer — there is nobody to pay it to and every stake is returned. Two settings that used to fight over this are now settled: `includeEntryPot` with `fighterBets.enabled = false` used to void every entry fee as "a bet held by a fighter" and hand the whole pot back, so nobody ever won it. An entry fee is not a bet anybody chose to place, and is no longer treated as one.

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
| *(none)* | client | The client registers no command at all. The lobby ped, or the marker, is the way in. |
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
- There is no command that opens the panel. Use the ped or the marker.
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
- No NPC standing there at all, with `ox_target is not started` in the console, is ox_target not running. Nothing goes up in its place: start ox_target, or set `Config.Lobby.interaction` to `'marker'` or `'both'`.
- Two NPCs standing on the same spot means something spawned one this resource did not. Its own ped is deleted on `onResourceStop`, so a plain restart cannot leave a duplicate behind.

### The sky arena does nothing, or I fall through it

Everything here is in **F8 on a client**, not the server console — the checks
are client-side because only a client can ask the game what models it has.

- **The round starts for everyone else and not for you.** The client refuses to
  place anybody into an arena whose floor did not build, because the
  alternative is a kilometre of air. It says so:

  ```
  [crimson_arena] arena scenery: NO FLOOR was built for an arena that supplies its own. Nobody is being placed into it -- there is nothing under it.
  ```

  You are taken back to the lobby and the server is told, so you are not left
  holding a place in a match you were never put into.

- **`PROPS MISSING ON THIS BUILD` at start** names which chain ran out. Every
  prop names five models across four DLCs ending in a base-game one, so a stock
  install should never see this — see `STREAMING.md` if you do.

- **With `Config.Debug = true`** the build reports itself:

  ```
  [crimson_arena] arena scenery: 215 of 215 piece(s) built -- 137 floor, 78 cover, furthest cover 44.53m out.
  [crimson_arena] arena scenery: the floor prop measures 40.00 x 40.00m and its surface is at 1201.00.
  ```

  **`0 floor` is the number that matters** — cover built and the floor did
  not. A piece count of zero entirely means the pieces were asked for
  somewhere the engine was not holding the map. A cover count well below 78,
  or a furthest cover far inside 44.53 m, means an older `config.lua`.

- **You are standing in the floor rather than on it, or the barriers are
  buried.** `platform.z` is the surface people stand on, not where the pieces
  are created — the client lowers each piece by its own measured height to
  meet it. That number has to agree with `spawnArea.center.z` and the arena's
  `boundary.center.z`; all three ship at 1201.

- **There is solid ground out past the boundary at the corners.** Deliberate.
  The floor is tiled and a tile is kept whenever any part of it falls inside
  the radius, because trimming to the radius leaves a hole and a hole here is
  fatal. Standing out there bleeds you exactly as leaving any other arena does.

- **Props left standing at 1201 after a match.** They are client-side local
  objects deleted on every exit path, including a resource stop. If you ever
  see one, it is a bug worth reporting — say what ended the round.

### Weapons are not being given

- The key must be in `Config.Loadouts.weapons` **and** `enabled ~= false`. A disabled weapon is indistinguishable from an unknown one, deliberately — otherwise `enabled = false` would only be a UI hint.
- Rejected keys produce a toast naming them. A panel left open across a config reload is the usual cause.
- **Off-list ammo falls back to `default`, it is not rounded.** If players report getting less ammo than they picked, check that the value is in that weapon's `options` list and not above its `max`.
- `weaponSlots` caps how many weapons are honoured. Entries past the cap are silently dropped — the request still succeeds.
- If it is the **ammo item** rather than the weapon that is missing, that is a different failure — see [Ammo items are not arriving](#ammo-items-are-not-arriving).
- A request that resolves to nothing still **succeeds**, and the player walks in empty-handed. If players are arriving unarmed, check that their chosen loadout resolved to something.
- Loadouts are re-resolved at match start against the live catalogue. Turn `Config.Debug` on to see what was dropped:

  ```
  [crimson_arena] [debug] dropped 1 loadout entr(ies) for 12 on match m4f2a1: grenadelauncher
  ```

### Ammo items are not arriving

- **Check the switch first.** `Config.Loadouts.ammoItems.enabled` ships `true`, so on a stock install this is *not* the answer — but if somebody has turned it off, nothing is asked of any inventory at all: the weapon arrives with the whole pick in its magazine and no item appears.
- **Check the amount you picked.** A weapon asked for one magazine or less has no spare rounds to issue, so no ammo item is handed over and none is missing. 30 rounds on a Pistol is 30 in the gun and nothing in the pocket, by design.
- **`ox_inventory` must be started.** If it is not, the console says so in as many words — `ammo items are switched on but ox_inventory is not started` — and nobody is given any.
- **The item name is worth checking.** Every shipped name is a real one, read out of that weapon's own `ammoname` in ox_inventory — `ammo-9`, `ammo-shotgun`, `ammo-heavysniper`. If your server names its ammo differently, a name that does not exist produces one console line per attempt: `ammo: could not give ammo-rifle x60 to 12 -- check that item exists on this server.` Nothing checks those names at startup, so this line is the only place a typo shows up.
- The same line appears for a **full inventory**, which is not a typo. `allowWeaponWithoutAmmoItem` decides whether that player still fights.
- **Melee weapons never carry an item.** That is by design, not a fault — see [what is not issued an item](#what-is-not-issued-an-item).
- A weapon with `ammoTypes = false`, or one whose ammo `max` is 1 or less, offers no types and so has no item to issue.

### Ammunition is not coming back

- **There is no per-item shortfall to read.** The exit clears the whole inventory rather than removing what was issued one item at a time, so spent rounds are not a discrepancy anybody has to account for.
- What will not come back is the player's OWN kit, and it is named: `door: <n> item(s) of <src>'s own kit could not be returned -- they stay in stash <id>.` The stash keeps it and the retry sweep hands it over when it can.
- **Check the door.** `Config.Loadouts.inventory.stripOnEntry` is what decides whether a player's own kit is taken and given back. With it off, players keep everything they walked in with *and* everything the arena issued — that is the switch that makes the arena a source of free ammunition, and it exists only for servers that want that.
- `door: refusing to drop match <id> -- <src>'s kit is still stashed at <stash>.` means a match record was asked to close while somebody's own belongings were still in the stash, and refused. The refusal is the safe outcome — the record stays reachable so a later return can still find it — but it is worth reading as a sign that an exit path did not run.

### A player's own inventory did not come back

- **It is not gone.** Everything a player walks in with goes into an
  ox_inventory stash named after their character, and nothing is ever taken
  out of that stash until it is provably back in their pockets. An item that
  will not go back is refused, not destroyed.
- **You do not have to do anything.** Whatever stopped it — a full inventory,
  a weight limit, a disconnect with no player left to hand things to, an
  ox_inventory that was restarting — the server checks again every
  `Config.Loadouts.inventory.returnRetrySeconds` (30 by default) and hands
  over anything still outstanding the moment it can. It survives the player
  reconnecting on a different id, and it survives a server restart, because
  the stash is named from the character and not from a server id.
- **It will not do it mid-round.** A player who is in a match is skipped
  until they are out of it, deliberately: the exit clears a player's whole
  inventory before it hands their own back, so putting their belongings into
  their pockets during a round is how they would get destroyed.
- `door: <n> item(s) of <src>'s could not be returned and are still in stash
  <name>` names the stash and the reason. The follow-up line, `handed <n>
  item(s) back to <src> out of stash <name>`, is the sweep finishing the job.
- **Set `returnRetrySeconds = 0` and none of that happens.** Anything that
  would not go back sits in the stash until somebody opens it by hand — which
  is what an operator is choosing when they turn it off.

### A player is still dead

- **`revive: NOTHING IS TELLING YOUR MEDICAL SCRIPT` in the console is not this.** Players are stood back up by the arena whatever that line says — see [getting back up after a death](#getting-back-up-after-a-death). That line is about telling a separate medical script, and on many servers there is nothing to tell.
- **Type `/arenarevive <id>`.** It runs exactly the same path a finished match runs, on demand, so you can test it without playing a round. If that puts them up, the revive works and the problem is upstream of it.
- **A player who looks alive but is treated as dead** — cuffed, bleeding out, refused a weapon, dragged by EMS — is the handoff, not the revive. Their ped is up; your medical script's own list has not been told. Add that script to the catalogue in `shared/compat/dispatch.lua`, with the revive event it listens for.
- **Still down right after a respawn?** Raise `Config.Dispatch.revive.afterRespawnDelayMs` (2000 by default). The revive has to land *after* the client has stood the ped up and finished the teleport; told sooner, whatever it does is undone by the teardown behind it.
- **Still down after the match ends?** `Config.Dispatch.revive.sweepAfterMatchMs` (5000 by default) is a second blanket pass over everyone who played, run once everybody is home. `0` turns it off; raise it if your teleport home is slow.
- **The arena runs no commands.** It asks the server for no permissions and has no channel for running one, which is why the handoff is an event a medical script publishes on purpose for other scripts to call.

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

### Two matches can see and shoot each other

That is isolation not happening, and the resource can now tell you which of three things it is rather than leaving you to guess.

**Type `/arenaisolation`.** It prints measurements, not intentions: the mode your server reports for `onesync`, whether a routing bucket has ever been set and then found not to have taken, the bucket each live match was allocated, and — the line that settles it — the bucket the server says each of those players is standing in right now.

```
[crimson_arena] arenaisolation: config says ON, server reports onesync "on", a move has NOT been caught not landing.
[crimson_arena] arenaisolation: isolation is IN FORCE right now, one bucket per match.
[crimson_arena] arenaisolation:   match m1f3a2 was allocated bucket 4210.
[crimson_arena] arenaisolation:   match m1f3a3 was allocated bucket 4211.
[crimson_arena] arenaisolation:   3 (match m1f3a2) should be in 4210 and the server says 4210.
[crimson_arena] arenaisolation:   7 (match m1f3a3) should be in 4211 and the server says 4211.
```

Two players with the same number and two different match ids is the whole diagnosis. So is a row ending `<-- NOT INSTANCED`.

- **`server reports onesync "off"`** — routing buckets need OneSync, and without it the natives that instance a match do nothing at all: no error, no warning. `set onesync on` in `server.cfg`, then restart. Note that `onesync_enabled 1`, `yes` and `on` all count as on; the arena reads all of them.
- **`a move has been caught not landing`** — the server accepted a routing bucket and then reported the player somewhere else. The natives are inert here whatever the convars say. Until it is fixed the arena refuses to start a second match at an arena somebody is already fighting in, rather than dropping two armed groups on one platform.
- **`config says OFF`** — `Config.Dispatch.isolation.enabled` is `false`. Turn it back on.

Like `/arenadispatch` and `/arenarevive`, it is gated on `Config.Permissions.adminGroups`, and the server console always qualifies.

### Nothing else fits

Set `Config.Debug = true` and restart. It is chatty by design — every stake, refund, payout, join and elimination is printed. Turn it back off on a live server.

---

## Development

```sh
luacheck .          # against .luacheckrc: exact native and global allow-list
tests/run.sh        # every tests/*_spec.lua under plain lua5.4, then tests/panel/ under node
```

`tests/panel/` is the odd one out: it loads the real, unmodified `html/app.js`
in a DOM shim under Node and asserts what the panel puts **on the wire**, not
what the source looks like. It exists because the panel is the one place a
value can be computed correctly and still never arrive — a field the form
never reads reaches the server as `undefined` and silently falls back, with
both ends looking right. It runs in CI, and `run.sh` skips it with a notice
where `node` is not installed rather than failing.

Both run on every push and pull request via `.github/workflows/lua-check.yml`, along with `luac5.4 -p` over every `.lua` file.

`shared/arena.lua` calls no native at all. That is what lets the test suite load the real, unmodified production file under plain Lua and exercise every rule directly.

---

## Licence

Copyright © John Allday. Proprietary — licensed to the purchaser for use on their own server. Not for redistribution, resale or public release.

# Crimson Arena

A configurable PvP arena for [Qbox](https://github.com/Qbox-project). Players walk up to an NPC, pick their weapons, melee and ammunition from lists you control, choose a team that does not have to be even, and optionally bet on the outcome.

By John Allday, for Crimson Roleplay.

## Install

**You need:** `qbx_core`, `ox_lib`, `ox_target` and `ox_inventory`. Every Qbox server already runs all four. There is **no SQL to import**.

1. Download this repository and open the archive.
2. Find the folder called **`Crimson-Arena`** inside it.
3. Drag that folder into your server's `resources/` folder. Do not rename it — it is already named the way it should be. (It does work under another name, but then you have to change the export lines at the bottom of this page to match.)
4. Open `server.cfg` and add this one line:

   ```cfg
   ensure Crimson-Arena
   ```

5. Put it in the right place — see below.
6. Start the server.

When it starts you will see `[crimson_arena]` lines in your server console telling you what it found and what it did not.

### Where the line goes in `server.cfg`

**The rule that is never optional:** it must come **after** the things it needs.

```cfg
ensure qbx_core
ensure ox_lib
ensure ox_target
ensure ox_inventory
ensure oxmysql          # only if you switch the database on

# ... the rest of your resources ...

ensure Crimson-Arena    # <- here, at the BOTTOM
```

Put it at the very bottom of `server.cfg` and it is after everything, which
satisfies that rule without you having to think about it. **That is the
recommended spot, and for most servers it is the end of the story.**

#### The one case where the position matters beyond that

If you run a dispatch or ambulance script (sc-dispatch, sc-ambulance,
ps-dispatch, anything that pages police and EMS), two things pull in
**opposite directions** and you cannot have both by moving one line:

| Put `ensure Crimson-Arena` | You get | You lose |
|---|---|---|
| **LAST** (bottom of the file) | The **team outline** draws in the arena's colour | Their death handler runs before the arena's, so an EMS page can be sent from the dying player's own client before anything here runs |
| **FIRST** (above the dispatch lines) | The arena's death handler goes first | The outline colour is one game-wide setting and the **last** resource to write it each frame wins — so the arena loses it, and teammates are outlined in somebody else's colour or not visibly at all |

**Which to pick:** if your team outline is working and you like it, leave
`Crimson-Arena` **last** and do not move it. Moving it up to chase alerts is
the single most common way to break an outline that was working.

**How to get both.** Order only matters because the other script does not
know a fighter is in the arena. Tell it, and the order stops mattering — one
line at the top of whatever raises the alert:

```lua
if Player(src).state.crimsonArena then return end        -- server realm
if LocalPlayer.state.crimsonArena then return end        -- client realm
```

That flag is set by the arena and is `nil` the moment a player leaves a
round. With those lines in place the alert is never raised at all, which is
the only way to get true silence — and then you are free to put
`ensure Crimson-Arena` wherever the outline wants it.

If you would rather not touch the other script, the arena still **withdraws**
the call after it is filed (`Config.Dispatch.custom.retract`). Your responders
get the ping and then watch it clear. That is a real difference from never
being paged, and it is worth knowing which of the two you have.

**Whatever you choose, restart the server** — `refresh`/`restart` does not
re-order anything, and the arena reports the order it actually saw in the
console at the first death of a round.

### Do I need a database?

**No.** It runs fine without one.

Turning `Config.Database.enabled` on in `Crimson-Arena/config.lua` adds two things and nothing else: the **all-time leaderboard**, and the arena's **record of what players still owe it** (so somebody who logs off mid-debt still owes it when they come back). Both need `oxmysql`. If you switch it on and `oxmysql` is not there, the arena says so in the console and carries on without it.

## Setting it up

Everything you change lives in **`Crimson-Arena/config.lua`**. Every setting has a comment right above it explaining what it does, so you can read it top to bottom and change what you want.

The three things most people change first:

| I want to… | Open | Look for |
|---|---|---|
| Move the lobby NPC somewhere else | `config.lua` | `Config.Lobby` |
| Change which guns are available | `config.weapons.lua` | the weapon list |
| Turn the arenas on or off, or move them | `config.lua` | `Config.Arenas` |

### Turning off the console spam

`Config.Debug` in `config.lua` ships **on**. It prints an extra line every time something interesting happens, in both the server console and every player's F8 console. Once the arena is working the way you want it:

```lua
Config.Debug = false
```

That silences the routine per-round reporting everywhere. Real problems — a prop your server does not have, a FiveM native your build is missing, a setting that is wrong — are still printed, but only **once per session** instead of once per round, so they tell you what is wrong without burying you.

## Admin commands

All of these need admin permission, which the arena reads from your framework.

| Command | What it does |
|---|---|
| `/arenaadmin` | **Start here.** Opens the admin tablet, and takes no arguments — everything is a button on the screen. **Matches:** force-stop one round or every round at once (everybody is refunded either way), and revive a fighter. **Stashes:** see whose belongings the arena is still holding, hand them back or queue them for when they return, and clear a hold on a stash the door has refused to empty. **Tools:** the police/EMS, instancing, attachment, opening-hours and held-back-stash readings, what the arena owes players, and a **Medical test** that runs the end-of-match revive against any server id so you can test your medical script without playing a round. |
| `/arenaconsole` | Prints all of those readings to the **server console** in one pass, for a box you cannot open a tablet on. Takes no arguments. The Medical test is not in it — that one revives a named player rather than reading the server, so it stays a button with a box to type the id into. |

## Documentation

Everything else lives inside the resource folder, so it travels with the copy on your server:

| | |
|---|---|
| **[`Crimson-Arena/README.md`](Crimson-Arena/README.md)** | Full documentation — every setting, what it does, and why it is the shape it is |
| **[`Crimson-Arena/config.lua`](Crimson-Arena/config.lua)** | Everything you edit except the weapon list. Every option is commented in place |
| **[`Crimson-Arena/config.weapons.lua`](Crimson-Arena/config.weapons.lua)** | The weapon catalogue, split out so the file above stays short |
| **[`Crimson-Arena/REFERENCE.md`](Crimson-Arena/REFERENCE.md)** | The inventory: every feature, command, export and event, and every function in every file with a line on what it is for |

## Why the resource is in a subfolder

So that the folder you drag out of the download is the folder you drop into `resources/`, correctly named, with no step in between. The repository root holds only this file, the CI workflow and the ignore list — none of which belong on a game server.

## Exports

These are for **other scripts** on your server — a dispatch script, a job script, anything that needs to know whether somebody is currently fighting. You do not need any of this to run the arena.

> ⚠️ **`'Crimson-Arena'` is your FOLDER name, not a magic word.** FiveM names a resource after the directory it sits in. If you renamed the folder, change it in every line below to match. An export naming a resource that does not exist **does not throw an error** — it silently returns nothing, which is the nastiest way for this to go wrong.
>
> If you would rather not worry about that, use the **state bag** at the bottom. It does not care what the folder is called.

### Server side

| Export | Gives you |
|---|---|
| `exports['Crimson-Arena']:IsPlayerInArena(src)` | `true` if that player is in a match right now, otherwise `false`. |
| `exports['Crimson-Arena']:GetPlayerMatchId(src)` | The id of the match they are in, or `nil` if they are not in one. |
| `exports['Crimson-Arena']:GetArenaPlayers()` | Everybody currently in a match, as a `[serverId] = matchId` table. It is a copy, so editing it changes nothing. |

```lua
-- Don't send police to a shooting that happened inside the arena.
if exports['Crimson-Arena']:IsPlayerInArena(source) then return end
```

### Client side

| Export | Gives you |
|---|---|
| `exports['Crimson-Arena']:IsInArena()` | `true` if **this** player is in a match. |
| `exports['Crimson-Arena']:GetArenaMatchId()` | The id of the match they are in, or `nil`. |

```lua
-- Don't let the player open their phone mid-fight.
if exports['Crimson-Arena']:IsInArena() then return end
```

### State bag — the one that does not care about the folder name

The arena writes a flag onto the player themselves. Anything on your server can read it, from either realm, with no export call and no event:

```lua
if Player(src).state.crimsonArena then return end        -- server side
if LocalPlayer.state.crimsonArena then return end        -- client side
```

The value is the match id (so it is truthy while they are fighting) and `nil` the moment they are not. The key is set by `Config.Dispatch.custom.stateBagKey` in `config.lua`, so if you change it there, change it in your script too.

### Events

The arena also fires an event when somebody enters and leaves a match, for scripts that would rather be told than ask. They ship as `crimson_arena:dispatch:enter` and `crimson_arena:dispatch:exit`, and both names are yours to change in `Config.Dispatch.custom` in `config.lua`. See the **Exports for other resources** section of [`Crimson-Arena/REFERENCE.md`](Crimson-Arena/REFERENCE.md) for what each one is handed.

## Licence

See [`Crimson-Arena/LICENSE.md`](Crimson-Arena/LICENSE.md).

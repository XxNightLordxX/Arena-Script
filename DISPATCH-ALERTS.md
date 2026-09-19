# Keeping police and EMS out of the arena

**Everything you have to change *outside* Crimson-Arena is in this one file.**
There are two scripts to touch and nothing else:

| Script | What to do | Effort |
|---|---|---|
| `sc-dispatch` | Set one line in **its own** config | one line |
| `sc-ambulance` | Paste two lines at the top of **two** handlers | two pastes |

Nothing needs setting up on the Crimson-Arena side. Everything both of them
read already ships.

> **If you only do the `sc-dispatch` half, EMS still gets paged for every arena
> death.** That is the trap this file exists to stop: `sc-ambulance` has no
> arena integration of its own, and its person-down handler goes round
> `sc-dispatch`'s check entirely. Part 2 is not optional on a box that runs it.

---

# Part 1 — `sc-dispatch` (police alerts)

```lua
-- sc-dispatch/config.lua
Config.Integrations = {
    CrimsonArena = true,
}
```

That is the whole job. There is no block to paste into `sc-dispatch`.

## What that switch does

`sc-dispatch` asks this resource whether a player is in an arena match, on that
player's **own client**, before it raises an alert at all. It gates four
things:

| What | Where, in sc-dispatch |
|---|---|
| Shots fired | `client/main.lua` — `TriggerShotsFiredAlert` |
| Person down (laststand) | `client/main.lua` — the laststand watcher |
| Person dead | `client/main.lua` — the death watcher |
| The manual "press G for help" EMS call | `client/main.lua` — the down-player loop |

Because it runs **before** the alert is raised, there is no call to withdraw
and nothing flashes on a medic's screen. That is strictly better than anything
this resource can do from its own side, which is why there is no longer a
Crimson-Arena-side block for it.

Its panic button is **not** gated, but it needs an on-duty officer to press it,
so a fighter cannot raise one.

## What Crimson-Arena provides for it

Two things, and it already provides both — this is here so you know what would
break it, not because there is anything to set up.

| What sc-dispatch reads | Who it covers | Written by |
|---|---|---|
| `LocalPlayer.state.crimsonArena.active` | **fighters and spectators** | `server/dispatch.lua`, replicated to the client |
| `exports['Crimson-Arena']:IsInArena()` | **fighters only** | `client/exports.lua` |

It tries the state bag first and falls back to the export, so it works even if
this resource is stopped or was never installed.

### The one way you can break it from this side

`Config.Dispatch.custom.stateBagKey` is renameable. **sc-dispatch reads
`crimsonArena` by that literal name.** Rename it and:

- fighters stay covered, because the export fallback catches them;
- **spectators stop being covered entirely**, because that export only answers
  for somebody actually placed in a round.

What that looks like in game: people sitting in the arena watching a match
start paging EMS and police about a round they are not even fighting in, and
nothing on either side saying why.

Leave the key alone unless it genuinely collides with something. If you do
change it, the admin tablet will tell you.

---

# Part 2 — `sc-ambulance` (medical alerts)

**Two lines, pasted at the top of two handlers, both in
`sc-ambulance/server/main.lua`:**

```lua
	local ok, quiet = pcall(function() return exports['Crimson-Arena']:ShouldSuppressAlert(src) end)
	if ok and quiet == true then return end
```

## Why this is needed even with Part 1 done

`sc-ambulance` is a separate resource and **has no arena integration at all** —
not a mention of this resource, a state bag, a combat zone or a paintball check
anywhere in it. It raises its own alerts, from its own client, down its own
events:

| Event | Raised from | Times |
|---|---|---|
| `hospital:server:ambulanceAlert` | `client/laststand.lua`, `client/dead.lua` (×2), `client/qbx_medical_compat.lua` (×3) | 6 |
| `hospital:server:EMSDownAlert` | `client/laststand.lua`, `client/dead.lua` | 2 |

All eight funnel into **two** server handlers, which is why two pastes cover
all eight.

### The part that catches people out

`hospital:server:EMSDownAlert`'s handler calls **`sc-dispatch`'s server
export** (`exports['sc-dispatch']:AddNotification`). Part 1's integration is a
*client* check, so a call arriving at its server export has already gone round
it. **A box can have `sc-dispatch` fully set up, read as covered, and still
have arena deaths reach EMS.** Neither path is closed from the Crimson-Arena
side.

### What each path actually costs you today

They are not equally bad, and the obvious reading gets it backwards.

| Path | With no paste |
|---|---|
| `hospital:server:EMSDownAlert` (2 sites) | The call reaches `AddNotification`, which announces the whole payload on `sc-dispatch:server:witnessForward` before it writes a row. Crimson-Arena's retract layer listens on exactly that event and the payload carries `caller_source`, so the call is **withdrawn about a quarter of a second later**. A medic on duty at that instant still sees it flash; nothing persists. |
| `hospital:server:ambulanceAlert` (6 sites) | Goes **straight** to every on-duty medic — the handler loops them and `TriggerClientEvent`s each one. No `sc-dispatch` call, no call id, **nothing to withdraw**. |

So paste **1** closes a permanent hole and is the one to do first; paste **2**
turns a flash-then-clear into never-raised. Six of the eight alert sites go
down the first one.

### Why Crimson-Arena cannot do it from its own side

`Config.Dispatch.custom.cancelEvents` can register a handler on both event
names and call `CancelEvent()`. It would change nothing: **`sc-ambulance` never
calls `WasEventCanceled()`**, so its handlers page every on-duty medic whether
the flag is raised or not. Both names are deliberately left out of that list
for exactly this reason, and `config.lua` says so where the list is defined.

## The two pastes

Line numbers are from the copy this was written against; if yours has drifted,
search for the event name.

### 1. `hospital:server:ambulanceAlert` — around line 258

Covers all six `ambulanceAlert` sites. Paste **after** `local src = source`:

```lua
RegisterNetEvent('hospital:server:ambulanceAlert', function(text)
	local src = source

	-- Crimson-Arena: no medical page for a fighter or a spectator in a round.
	local ok, quiet = pcall(function() return exports['Crimson-Arena']:ShouldSuppressAlert(src) end)
	if ok and quiet == true then return end

	local ped = GetPlayerPed(src)
	...
```

### 2. `hospital:server:EMSDownAlert` — around line 271

Covers both `EMSDownAlert` sites — the server-export path above, whose calls
are currently withdrawn a beat after they are raised rather than never raised.
Paste **after** `local src = source`, **before** the `Config.MDTIntegration`
check:

```lua
RegisterNetEvent('hospital:server:EMSDownAlert', function(street)
	local src = source

	-- Crimson-Arena: no medical page for a fighter or a spectator in a round.
	local ok, quiet = pcall(function() return exports['Crimson-Arena']:ShouldSuppressAlert(src) end)
	if ok and quiet == true then return end

	if not (Config.MDTIntegration and Config.MDTIntegration.Enabled) then return end
	...
```

### 3. Optional — the `/311` command, around line 744

`sc-ambulance` also lets a player type `/311` to page EMS, and that works from
inside the arena like anywhere else. It is a deliberate act rather than
something a fighter's death does to them, so guard it only if you do not want
fighters paging medics on purpose. Same two lines, after that handler's
`local src = source`.

## Why it is written that way

**`ShouldSuppressAlert` and not `IsPlayerInArena`.** An alert is raised *from a
death*, and a death resolves on a schedule the arena does not control: the
round ends, the flag comes down, and milliseconds later `sc-ambulance` files a
person-down call for a body that was in the arena when it fell.
`IsPlayerInArena` answers that honestly with `false` and the page goes out.
`ShouldSuppressAlert` stays `true` for a few seconds after a **fighter**
leaves, which closes that gap. It also covers **spectators** for as long as
they are watching, and a spectator who stops watching earns no window at all.

**Wrapped in `pcall`, and `ok and quiet == true` rather than just `quiet`.** If
Crimson-Arena is stopped, restarting, or simply not installed, asking for the
export *raises* rather than answering `nil`. Unwrapped, that error would abort
the whole handler — and a `sc-ambulance` handler that aborts is a real player
bleeding out in the city with nobody paged. Written this way, anything going
wrong means **the alert goes out**, which is the safe direction to fail. The
lines are also safe to leave in place on a server that does not run
Crimson-Arena at all.

**It reads `src`, which both handlers already have** on their first line. Do
not move the paste above it.

---

# Checking both halves took

Admin tablet → **Tools** → **Police & EMS**, or `/arenaconsole` at a server
console. The last two lines are about the two halves above.

**The `sc-dispatch` line** says one of:

- `sc-dispatch is running with Integrations.CrimsonArena = true ...` — Part 1 done.
- `... Integrations.CrimsonArena in its own config is FALSE ...` — set it to true.
- `... stateBagKey here is "x" and sc-dispatch reads "crimsonArena" ...` — see Part 1.
- `sc-dispatch is not running ...` — Part 1 is not your route; the other layers apply.

**The `sc-ambulance` line** says one of:

- `sc-ambulance is running and both of its alert handlers (2 of 2) carry an arena guard ...` — Part 2 done.
- `... there is NO arena guard in ... so an arena death still pages every on-duty medic ...` — the paste is not in that handler.
- `... cannot find ... written the way it reads them ...` — your build's handlers differ; check by hand.
- `... its server/main.lua could not be read from here ...` — usually an escrowed or moved file.
- `sc-ambulance is not running ...` — nothing to do.

The `sc-ambulance` check reads `sc-ambulance/server/main.lua`, finds each
handler, and looks for the text `Crimson-Arena` inside **that handler's own
body**. It is a read and never a write. It judges each handler separately, so a
guard in one is never counted for the other — and it does **not** look at
`/311`.

If you rename the resource folder, the comment in the paste stops matching and
the tablet reports the guard as missing even though it works. The
`exports['Crimson-Arena']` call carries the name too, so keeping the folder
name is the simplest answer.

---

# If you run neither script

The other layers still apply and are documented in `Crimson-Arena/README.md`
under *Keeping police and EMS out of the arena* — routing-bucket isolation, the
instant dead-state clear, the retract sweep, and, for any script you can edit,
one line at the top of whatever raises the alert:

```lua
if Player(src).state.crimsonArena then return end        -- server realm
if LocalPlayer.state.crimsonArena then return end        -- client realm
```

If you replace `sc-ambulance`, the same two lines from Part 2 go at the top of
whatever the replacement uses to page medics.

---

# What used to be here

This file used to carry a ~230 line block to paste at the bottom of
`sc-dispatch/server/main.lua`, which wrapped its `AddNotification` export and
dropped alerts for arena fighters.

**It never worked, and it is gone.** In FiveM an export resolved through
`TriggerEvent` arrives as a msgpack **funcref table**, not a function — so the
block's `if type(original) ~= 'function'` gate always took its bail-out path,
printed *"could not find this resource's AddNotification export"*, and
registered nothing. Its own test suite passed because the test harness handed
the callback a raw Lua closure instead of round-tripping it the way the real
runtime does.

Do not go looking for it in your sc-dispatch. If you pasted it previously,
delete the block — it is inert, but it is 230 lines of nothing.

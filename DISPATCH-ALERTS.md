# Keeping police and EMS out of the arena

**Everything you have to change *outside* Crimson-Arena is in this one file.**
There are two scripts to touch and nothing else:

| Script | What to do | Effort |
|---|---|---|
| `sc-dispatch` | Set one line in **its own** config — **on a build that ships the arena check.** Part 1 says how to tell, and what to paste if yours does not | one line, or one paste |
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
-- sc-dispatch/config.lua -- set the one key; do not replace the table
Config.Integrations = {
    PugPaintball = false,    -- leave whatever is already here alone
    CrimsonArena = true,     -- <- this is the line
}
```

`Config.Integrations` already exists in that file and has other keys in it.
**Set `CrimsonArena`; do not paste over the table** — dropping `PugPaintball`
on a server running pug-paintball starts filing shots-fired calls for paintball
matches, with nothing saying why.

## FIRST — check that your `sc-dispatch` can read that key

**Not every build of `sc-dispatch` can.** The integration is something
`sc-dispatch` itself added, and a build without it has no code that looks at
`Config.Integrations.CrimsonArena` at all — so setting the key does **nothing
whatsoever**, and you would be left believing police alerts are handled when
every one of them still fires. Both builds report `version '1.0.1'`, so the
version string will not tell you.

Run this against your own copy:

```
grep -n "IsInCrimsonArena" sc-dispatch/client/main.lua
```

- **Something comes back** → your build has it. Set the key as above. **That is
  the whole job, and there is no block to paste.** Skip to *What that switch
  does*.
- **Nothing comes back** → your build does not have it. Do the paste below
  instead, and set the key anyway so it keeps working if you update later.

### If your build does not have it

Add this **once**, at the very bottom of `sc-dispatch/client/main.lua`:

```lua
-- Crimson-Arena: no shots-fired, person-down or person-dead calls from inside
-- an arena match. Paste ONCE, at the very bottom of the file.
local scOriginalIsInPaintball = IsInPaintball

function IsInPaintball()
    local arena = LocalPlayer.state.crimsonArena
    if arena and arena.active then return true end

    if GetResourceState('Crimson-Arena') == 'started' then
        local ok, inArena = pcall(function()
            return exports['Crimson-Arena']:IsInArena()
        end)
        if ok and inArena == true then return true end
    end

    return scOriginalIsInPaintball()
end
```

**The `local` line comes first, and it matters more than it looks.** It has to
be above the function so the function closes over it. Below it, the name inside
the function is a *global* that is never assigned — nil — and calling it raises.

This covers the three gates an older build has. It **cannot** cover the manual
"press G for help" EMS call, because that build has no check on it at all — not
even for paintball. Part 2's `EMSDownAlert` paste is what covers that one.

### ⚠ If you already pasted an older version of this, delete it

A block of this shape may already be at the bottom of your
`sc-dispatch/client/main.lua` — **two** `function IsInPaintball()` definitions,
one of them calling `scOriginalIsInPaintball()` *before* the
`local scOriginalIsInPaintball = ...` line that creates it:

```lua
function IsInPaintball()
    if GetResourceState('Crimson-Arena') == 'started' then
        ...
    end
    return scOriginalIsInPaintball()     -- nil here: the local is declared BELOW
end
-- Crimson Arena: no shots-fired or person-down calls from inside an arena.
local scOriginalIsInPaintball = IsInPaintball
function IsInPaintball()
    ...
end
```

**Delete the whole thing and use the single block above.** It is not merely
useless — it raises. Measured, by running it:

| Player is | What `IsInPaintball()` does |
|---|---|
| in an arena match | returns `true` — correct |
| **anywhere else** | **raises** `attempt to call a nil value (global 'scOriginalIsInPaintball')` |
| in a paintball match | never reached — raises first |

"Anywhere else" is almost everyone, almost always. Every gate that calls it —
shots fired, person down, person dead — raises instead of answering, so
**ordinary police alerts for the rest of your city stop working**, and
pug-paintball stops being gated too. The arena stays covered the whole time,
which is exactly why it can sit there unnoticed.

## What that switch does

`sc-dispatch` asks this resource whether a player is in an arena match, on that
player's **own client**, before it raises an alert at all. On a build that
ships the check it gates four things, through `IsInCombatSafeZone()`:

| What | Where, in sc-dispatch | Covered by the paste above? |
|---|---|---|
| Shots fired | `client/main.lua` — `TriggerShotsFiredAlert` | yes |
| Person down (laststand) | `client/main.lua` — the laststand watcher | yes |
| Person dead | `client/main.lua` — the death watcher | yes |
| The manual "press G for help" EMS call | `client/main.lua` — the down-player loop | **no** — an older build has no check on that loop at all, not even for paintball. Part 2's `EMSDownAlert` paste is what covers it |

Because it runs **before** the alert is raised, there is no call to withdraw
and nothing flashes on a medic's screen. That is strictly better than anything
this resource can do from its own side, which is why there is no longer a
Crimson-Arena-side block for it.

Its panic button is **not** gated. It needs the presser to be **on duty** as
police, EMS or fire, so a civilian fighter cannot raise one — but an on-duty
medic or officer who walks into a match can.

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

| Event | Raised from | Live sites |
|---|---|---|
| `hospital:server:EMSDownAlert` | `client/laststand.lua:97`, `client/dead.lua:228` | 2 |
| `hospital:server:ambulanceAlert` | `client/laststand.lua:99`, `client/dead.lua:71`, `client/dead.lua:230` | 3 |

They all funnel into **two** server handlers, which is why two pastes cover
every one of them.

`client/qbx_medical_compat.lua` raises `ambulanceAlert` three more times and is
**not in sc-ambulance's `fxmanifest.lua`** — it is never loaded, so those three
do not count. If a future version adds it to the manifest, the same two pastes
already cover it.

### The part that catches people out

`hospital:server:EMSDownAlert`'s handler calls **`sc-dispatch`'s server
export** (`exports['sc-dispatch']:AddNotification`). Part 1's integration is a
*client* check, so a call arriving at its server export has already gone round
it. **A box can have `sc-dispatch` fully set up, read as covered, and still
have arena deaths reach EMS.** Neither path is closed from the Crimson-Arena
side.

### Which one actually fires on your box

**Do paste 2 first.** With `sc-ambulance`'s shipped config
(`MDTIntegration.Enabled = true`, `DisableDefaultAlerts = true`) and
`sc-dispatch` running, `EMSDownAlert` is the **only** one of the two that ever
fires.

All three live `ambulanceAlert` sites are dormant on that config, though not by
the same mechanism, and the difference matters if you change a setting:

- `client/laststand.lua:99` and `client/dead.lua:230` are the `else` of
  `MDTIntegration.Enabled and GetResourceState('sc-dispatch') == 'started'` —
  they wake up if the integration is disabled **or sc-dispatch stops**.
- `client/dead.lua:71` is gated on
  `not (MDTIntegration.Enabled and DisableDefaultAlerts)` and never consults
  `sc-dispatch` at all — it wakes up only if one of those two settings is
  turned off.

| Path | Fires as shipped? | With no paste |
|---|---|---|
| `hospital:server:EMSDownAlert` (2 sites) | **Yes — this is the live one.** | The call reaches `AddNotification`, which files it under `emsdown_<serverId>_<os.time()>`. That shape is one of Crimson-Arena's shipped `idTemplates`, so the retract sweep rebuilds exactly that id and the call is **withdrawn** — but **at the revive**, not instantly, so it sits on a medic's screen for the length of the down. The instant route exists and **ships off**: `AddNotification` also announces the whole payload on `sc-dispatch:server:witnessForward` before it writes a row, and Crimson-Arena will withdraw off that announcement within `delayMs` **if you set `Config.Dispatch.custom.retract.filedEvent` to it**. It ships empty on purpose — with `Config.Security.ServerOnlyDispatches` false, any client can send that announcement a `unique_id` and a `caller_source` that do not belong together, which would withdraw a stranger's emergency call. Set `ServerOnlyDispatches = true` first, then fill the event in. |
| `hospital:server:ambulanceAlert` (3 sites) | No, not as shipped. Live if `MDTIntegration.Enabled` or `DisableDefaultAlerts` is turned off, or `sc-dispatch` stops. | Goes **straight** to every on-duty medic — the handler loops them and `TriggerClientEvent`s each one. No `sc-dispatch` call, no call id, **nothing to withdraw**. |

So: paste **2** stops what is happening today. Paste **1** costs nothing now and
is what stands between you and a permanent, un-withdrawable hole the day
somebody flips one of those two settings or `sc-dispatch` is down. Do both.

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

Covers all three live `ambulanceAlert` sites (and the three in the unloaded
compat file, if it is ever added to the manifest). Dormant on the shipped
config; the one that leaves nothing to withdraw when it is not. Paste **after**
`local src = source`:

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

**The one that fires today.** Covers both `EMSDownAlert` sites — the
server-export path above, whose calls are currently withdrawn at the revive
rather than never raised. Paste **after** `local src = source`,
**before** the `Config.MDTIntegration` check:

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

**The colon is load-bearing.** `exports['Crimson-Arena']:ShouldSuppressAlert(src)`
with a `.` instead of a `:` passes the exports table itself as the first
argument and `src` as the second, so the export answers about nobody, returns
`false`, and **every arena alert goes out** — with no error and nothing in the
console. The admin tablet cannot catch this one either: the line is there and
it names the resource, so it reads as a guard. Copy the block, do not retype
it.

---

# Checking both halves took

Admin tablet → **Tools** → **Police & EMS**, or `/arenaconsole` at a server
console. The last two lines are about the two halves above.

**The `sc-dispatch` line** says one of:

- `sc-dispatch is running with Integrations.CrimsonArena = true ...` — the key is set.
  **That is not the same as the key being read.** This line reads
  `sc-dispatch`'s config; it cannot tell whether that build has the code that
  looks at the key. On a build without it the key is set, this line is green,
  and every police alert still fires. Run the `grep` in Part 1 once — it is the
  only thing that answers that question.
- `... Integrations.CrimsonArena in its own config is FALSE ...` — set it to true.
- `... stateBagKey here is "x" and sc-dispatch reads "crimsonArena" ...` — see Part 1.
- `... Its config could not be read from here ...` — usually an escrowed or moved config; check the setting by hand.
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

It reads the **code** on each line, with any trailing comment cut off first, so
a guard that has been commented out — or a paste where only the comment line
survived a merge — is reported as missing, which is what it is. It accepts two
forms: a line naming `Crimson-Arena`, or a line naming your
`Config.Dispatch.custom.stateBagKey` (`crimsonArena` by default), so the state
bag form `config.lua` suggests counts too.

**If you rename the resource folder**, `exports['Crimson-Arena']` has to change
with it, and the tablet then reports the guard as missing — the name it looks
for is the folder name, not the `name` field in `fxmanifest.lua`. The guard
still works; the report is what goes wrong. Keeping the folder name is the
simplest answer. (`sc-dispatch` hard-codes `Crimson-Arena` too, so a rename
costs you Part 1 as well.)

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

**One caveat on the server-realm form, which `config.lua` carries and this file
used not to.** A replicated state bag can be written by a client as well as by
the server, so a player who has never been near the arena could in principle pin
that flag on themselves and have your dispatch script politely ignore them
robbing a bank. Crimson-Arena only ever writes it from the server, but reading
it on the server means trusting a value the client can also set.

`exports['Crimson-Arena']:ShouldSuppressAlert(src)` — the export Part 2 uses —
has no such hole: it answers from a table inside this resource that nothing
outside it can write. **On the server, prefer the export.** The bag is the right
answer on the client, where the player could lie to themselves and gain nothing.

If you replace `sc-ambulance`, the same two lines from Part 2 go at the top of
whatever the replacement uses to page medics.

---

# What used to be here

A file called `ALERT-GUARD.md` used to sit beside this one and carry a ~230 line
block to paste at the bottom of `sc-dispatch/server/main.lua`, which wrapped its
`AddNotification` export and dropped alerts for arena fighters. That file is
gone and this one replaced it, which is why the link you followed may have
pointed somewhere that no longer exists.

**It never worked, and it is gone.** In FiveM an export resolved through
`TriggerEvent` arrives as a msgpack **funcref table**, not a function — so the
block's `if type(original) ~= 'function'` gate always took its bail-out path,
printed *"could not find this resource's AddNotification export"*, and
registered nothing. Its own test suite passed because the test harness handed
the callback a raw Lua closure instead of round-tripping it the way the real
runtime does.

Do not go looking for it in your sc-dispatch. If you pasted it previously,
delete the block — it is inert, but it is 230 lines of nothing.

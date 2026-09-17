# Stopping arena alerts at the source

**What this is:** one block of Lua you paste at the **very bottom of
`sc-dispatch/server/main.lua`**. After it, no police or EMS alert is ever
*raised* for somebody fighting in the arena — not raised and then withdrawn,
never raised at all.

**It is safe to paste whether or not you run Crimson Arena.** With the arena
stopped, missing, or never installed, the block asks its question, gets
nothing back, and passes every alert straight through unchanged. It is a
pass-through by default and a filter only when the arena says so.

---

## Why this exists

Crimson Arena already has five layers between an arena death and a medic's
screen (`Crimson-Arena/README.md` lists them all). The strongest one that does
not need anybody's cooperation is **routing-bucket isolation** — an arena match
is fought in its own network instance, so no other player's client sees arena
gunfire or arena bodies at all.

What isolation does not cover is the **server**. `sc-dispatch` files a
person-down call from a server event, and the server can see everyone. The
arena's answer to that today is `Config.Dispatch.custom.retract`: it lets the
call be filed and then calls sc-dispatch's own clear export for it. Your medics
get the ping, and then watch it disappear a second or two later.

That is a real difference from never being paged. This block closes it.

---

## Where it goes, exactly

| | |
|---|---|
| **File** | `sc-dispatch/server/main.lua` |
| **Position** | the very bottom, after everything else in the file |
| **Realm** | server — this file is already a `server_script`, so there is nothing to change in `fxmanifest.lua` |

**The position is not a style preference.** The block takes a copy of
sc-dispatch's `AddNotification` handler at the moment it runs, and that handler
is registered around line 2571. Paste it anywhere above that and there is
nothing to take a copy of — the block will say so in your console and do
nothing at all, which is the safe failure, but it is still a failure.

**Do not paste it into `config.lua`.** `config.lua` is a `shared_script` and
loads *before* `server/main.lua`, so it hits exactly that problem, and it also
runs on every client, where none of this belongs.

---

## What it covers

`AddNotification` is the single funnel every dispatch-panel alert on this
server goes through. That includes alerts **sc-dispatch does not raise itself**:

| Raised by | Path | Covered |
|---|---|---|
| sc-dispatch | `sc-dispatch:server:ShotsFired` → `AddNotification` | yes |
| sc-dispatch | `sc-dispatch:server:PlayerDown` → `AddNotification` | yes |
| sc-dispatch | `sc-dispatch:server:PlayerDead` → `AddNotification` | yes |
| sc-dispatch | `sc-dispatch:server:PanicButton` → `AddNotification` | yes |
| sc-dispatch | `sc-dispatch:server:AddNotification` (net event) | yes |
| **sc-ambulance** | `hospital:server:EMSDownAlert` → `exports['sc-dispatch']:AddNotification` | **yes** |
| **sc-ambulance** | doctor alert → `exports['sc-dispatch']:AddNotification` | **yes** |
| any other resource | `exports['sc-dispatch']:AddNotification(...)` | yes |

One paste, both scripts. You do not need to touch `sc-ambulance` for any of
the above.

### The one path it does not reach

`sc-ambulance` has a second, older alert of its own that never goes near
sc-dispatch:

```
hospital:server:ambulanceAlert  →  TriggerClientEvent('hospital:client:ambulanceAlert', ...)
```

Nothing pasted at the bottom of a file can stop that one: it is a
`RegisterNetEvent` handler, extra handlers are added rather than substituted,
and `CancelEvent()` after the fact clears nothing.

**It is already covered by something else, and this is worth understanding
rather than taking on trust.** Every client-side call site for that event sits
inside an "am I down / am I dead" branch, and
`Config.Dispatch.clearDeadStateImmediately` — on by default — puts an arena
casualty back on their feet in the *same instant* they go down. The branch is
never entered, so the event is never sent. What that depends on is start order:
if `ensure Crimson-Arena` sits below `ensure sc-ambulance` in `server.cfg`,
sc-ambulance's death handler runs first and can get the event out before the
arena resurrects. The arena prints the order it actually saw at the first death
of a round — read that line once and you will know which side of it you are on.

If you would rather close it by hand, it is one line at the top of that handler
in `sc-ambulance/server/main.lua`:

```lua
RegisterNetEvent('hospital:server:ambulanceAlert', function(text)
    local src = source
    if Player(src).state.crimsonArena then return end    -- <-- add this line
```

That is an edit *inside* an existing function, not a paste at the bottom, which
is why it is not part of the block below.

---

## The block

Paste everything between the two rules, at the bottom of
`sc-dispatch/server/main.lua`.

---

```lua
-- ============================================================================
-- CRIMSON ARENA ALERT GUARD
--
-- Drops police / EMS alerts raised for a player who is fighting in the arena,
-- before the call is filed, before the DB insert, before anybody's screen.
--
-- SAFE WITHOUT CRIMSON ARENA. If that resource is stopped, missing, or was
-- never installed, every question below answers "no" and every alert goes
-- through exactly as it does today. This block changes nothing on its own.
--
-- Paste at the VERY BOTTOM of sc-dispatch/server/main.lua. Nothing above it
-- needs changing. Delete the whole block to undo it.
-- ============================================================================
do
    -- The arena's folder name. Change this ONLY if you renamed the resource.
    local ARENA = 'Crimson-Arena'

    local SELF = GetCurrentResourceName()
    local GUARDED_EXPORT = 'AddNotification'

    -- ------------------------------------------------------------------
    -- 1. TAKE A COPY OF THE REAL HANDLER, BEFORE REGISTERING OURS.
    --
    -- This asks the runtime for the function that is registered for
    -- AddNotification RIGHT NOW. It has to happen first: once our wrapper is
    -- registered it becomes the one the runtime hands out, and a wrapper that
    -- resolved its "original" afterwards would find itself and recurse until
    -- the server stack gave out.
    -- ------------------------------------------------------------------
    local original
    pcall(function()
        TriggerEvent(('__cfx_export_%s_%s'):format(SELF, GUARDED_EXPORT), function(cb)
            original = cb
        end)
    end)

    -- NOTHING TO WRAP IS A REASON TO STOP, NOT A REASON TO GUESS. Registering
    -- a wrapper with no original behind it would silently delete every alert
    -- on the server. If you see this line, the block is too high up the file:
    -- it must sit below where AddNotification is registered.
    if type(original) ~= 'function' then
        print('[crimson-arena-guard] could not find this resource\'s ' .. GUARDED_EXPORT
            .. ' export, so NOTHING was changed. Move this block to the very bottom of the file.')
        return
    end

    -- ------------------------------------------------------------------
    -- 2. WHO IS THIS ALERT ABOUT?
    --
    -- Two shapes, because sc-dispatch uses both. `caller_source` is set on
    -- the person-down and person-dead calls. The rest carry the player only
    -- inside their unique_id, which is built as "<kind>_<serverId>_<time>"
    -- (shots_12_1699..., panic_12_1699..., emsdown_12_1699...).
    --
    -- NO SUBJECT MEANS NO SUPPRESSION. A dispatcher-created call or an alert
    -- about a place rather than a person is somebody else's business.
    -- ------------------------------------------------------------------
    local function subjectOf(data)
        if type(data) ~= 'table' then return nil end

        local direct = tonumber(data.caller_source)
        if direct and direct > 0 then return direct end

        local uid = data.unique_id
        if type(uid) ~= 'string' then return nil end

        -- ANCHORED AT BOTH ENDS on purpose. An unanchored match would read
        -- the timestamp, or any number sitting in a free-text id, as a
        -- player. A wrong id here silences a real emergency.
        local id = uid:match('^%a+_(%d+)_%d+$')
        id = tonumber(id)
        if id and id > 0 then return id end

        return nil
    end

    -- ------------------------------------------------------------------
    -- 3. ASK THE ARENA.
    --
    -- Two ways of asking, and the second one is why this works on a server
    -- that does not run the arena at all.
    --
    --   a. ShouldSuppressAlert -- the arena's own answer. It covers a player
    --      who left a match SECONDS ago as well as one still in it, which
    --      matters more than it sounds: a round resolves and the flag comes
    --      down, and the person-down call for the body that just fell is
    --      filed milliseconds later.
    --
    --   b. The replicated state bag, if that export is not there. Older arena
    --      builds have the bag and not the export.
    --
    -- EVERYTHING IS pcall'd AND EVERY FAILURE MEANS "RAISE THE ALERT". A
    -- spurious alert during an arena round is an annoyance. A swallowed one
    -- for a real player bleeding out in the city is not.
    -- ------------------------------------------------------------------
    local function inArena(src)
        if GetResourceState(ARENA) ~= 'started' then return false end

        local asked, answer = pcall(function()
            return exports[ARENA]:ShouldSuppressAlert(src)
        end)
        if asked and type(answer) == 'boolean' then return answer end

        local read, bag = pcall(function()
            return Player(src).state.crimsonArena
        end)
        return read and bag ~= nil
    end

    -- ------------------------------------------------------------------
    -- 4. THE WRAPPER.
    --
    -- Registering this name again makes ours the handler the runtime hands
    -- out from here on. `original` was captured in step 1, so the real
    -- function is called directly rather than looked up again.
    --
    -- IT NEVER THROWS, and that is load-bearing rather than tidy:
    -- sc-ambulance calls AddNotification inside a pcall and FALLS BACK to its
    -- own direct EMS alert when that pcall fails. An error in here would not
    -- suppress an alert -- it would send the very one we are suppressing, by
    -- a route this block cannot see.
    --
    -- IT RETURNS WHAT THE REAL ONE RETURNS, and nil when it suppresses.
    -- sc-dispatch's own callers already read that return as "the call could
    -- not be filed" and handle it.
    -- ------------------------------------------------------------------
    local inside = false

    local function guarded(data)
        -- RE-ENTRANCY BELT AND BRACES. If anything ever made `original`
        -- resolve back to this function, passing through is survivable and
        -- recursing is not.
        if inside then return original(data) end

        local src = subjectOf(data)
        if src then
            local ok, suppress = pcall(inArena, src)
            if ok and suppress then return nil end
        end

        inside = true
        local ok, result = pcall(original, data)
        inside = false

        if not ok then error(result, 0) end
        return result
    end

    exports(GUARDED_EXPORT, guarded)

    -- ------------------------------------------------------------------
    -- 5. PROVE IT TOOK, AND THEN SAY SO.
    --
    -- NOT "this block ran" -- "the runtime is handing out OUR function". Those
    -- are different claims and only the second is worth anything. A marker
    -- export under a brand-new name registers whether or not the
    -- re-registration above replaced anything, so a marker that only proved
    -- the block reached the bottom would report success on a build where the
    -- guard does nothing at all.
    --
    -- Asked the same way the original was captured in step 1: run the
    -- export's resolution and see whose function comes back.
    -- ------------------------------------------------------------------
    local function serving()
        local served
        pcall(function()
            TriggerEvent(('__cfx_export_%s_%s'):format(SELF, GUARDED_EXPORT), function(cb)
                served = cb
            end)
        end)
        return served == guarded
    end

    -- The arena's own report asks for this by name, so an operator can
    -- confirm the paste from the admin tablet instead of by dying in the
    -- arena and watching a medic's screen.
    exports('CrimsonArenaAlertGuard', serving)

    if serving() then
        print('[crimson-arena-guard] active: arena alerts will not be raised.')
    else
        print('[crimson-arena-guard] INSTALLED BUT NOT IN EFFECT -- something registered after '
            .. 'this block is answering ' .. GUARDED_EXPORT .. '. Alerts are unchanged. Move this '
            .. 'block lower, or find what else is wrapping that export.')
    end
end
-- ============================================================================
-- END CRIMSON ARENA ALERT GUARD
-- ============================================================================
```

---

## Checking it took

Three ways, in the order they cost you least:

1. **Your server console at startup.** One of three lines, and they mean
   different things:

   | Line | What it means |
   |---|---|
   | `active: arena alerts will not be raised.` | Working. The runtime is serving the guard. |
   | `could not find this resource's AddNotification export, so NOTHING was changed` | The block is **above** line 2571. Move it further down. Nothing was changed, so nothing is broken. |
   | `INSTALLED BUT NOT IN EFFECT` | The block ran, but something registered **after** it is answering `AddNotification` — a second copy of this block, or another resource's own wrapper. Alerts are unchanged. |

   That last check is an identity test, not a "did I get this far" flag: the
   block asks the runtime which function it is really serving for
   `AddNotification` and compares it to its own. A marker that only proved the
   block reached the bottom would report success on a build where the guard
   does nothing.

2. **The arena's own report.** Open the admin tablet → **Tools** → the dispatch
   compat reading, or run `/arenaconsole` at the server console. The
   last line names every dispatch script it detected and says which of them the
   guard is live in:

   ```
   the paste-in alert guard is live in: sc-dispatch. Alerts for fighters are never raised.
   ```

   Before the paste, the same line reads
   `the paste-in alert guard is in NONE of: sc-dispatch`.

3. **A round.** Have somebody on EMS duty watch their panel while a match runs.
   Nothing should appear — not appear-and-clear.

## Undoing it

Delete the block. Nothing else in `sc-dispatch` was changed, and the arena
falls back to `Config.Dispatch.custom.retract`, which withdraws the call after
it is filed.

## If you renamed the arena resource

Change `local ARENA = 'Crimson-Arena'` on the second line of the block to
whatever your folder is called. Nothing else in the block refers to it.

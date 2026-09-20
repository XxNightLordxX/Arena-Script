-- Crimson Arena: keeping arena gunfire off the city call system.

ArenaDispatch = {}

local active = {}

--- When each player last LEFT a match, as os.time(), for the withdrawal
--- window below, and for ShouldSuppressAlert.
local leftAt = {}

--- Server ids whose holder has DISCONNECTED and whose grace window must not
--- be re-opened by the exit paths still unwinding behind them.
---
--- WHY A SECOND TABLE RATHER THAN JUST CLEARING leftAt. The playerDropped
--- handler below used to do exactly that, and it did not work, because it is
--- not the last thing to run for a dropping player. This resource loads
--- server/dispatch.lua BEFORE server/main.lua, FiveM runs handlers in
--- registration order, and main.lua's own playerDropped handler detaches the
--- player -- which reaches ArenaDispatch.Clear with active[src] STILL SET,
--- and Clear stamped leftAt right back. So the one case the forget existed
--- for, dropping while flagged, was the one case it never covered: the id
--- went back in the pool carrying a live grace window, and the next person
--- handed it had a real city alert suppressed on the strength of somebody
--- else's round.
---
--- CLEARED BY Set, not by a timer and not by a join handler. An id is only
--- interesting again once somebody on it enters a match, and that is the one
--- moment this resource is certain a new player owns it.
---
--- WHAT IT ACTUALLY ADDS TODAY, said accurately rather than generously: the
--- drop handler ALSO nils `fighter[src]` on the line above it, and Clear needs
--- BOTH `fighter[src]` and `not dropped[src]` to stamp a window.
--- So either line alone already closes the drop-while-flagged case, and
--- removing this table changes no answer the suite can produce -- measured.
--- The two are defence in depth on a path whose failure is somebody's real
--- ambulance being silently swallowed, and they fail independently: `fighter`
--- is about WHO, this is about WHETHER THEY ARE STILL HERE. Keep both, and do
--- not read either as the only thing holding it.
---
--- BOUNDED, NOT A LEAK. Keyed by FiveM server id, which is bounded by the
--- server's slot count and recycled, so this table cannot grow past it.
local dropped = {}

--- Which flagged players are FIGHTERS rather than spectators. Read only when
--- deciding whether leaving earns a grace window; see ArenaDispatch.Set.
local fighter = {}

--- How long after leaving a match the SWEEP may still withdraw a call, in
--- seconds. Long enough to cover server/match.lua's post-match revive sweep,
--- which runs after the flag comes down; short enough that it is nowhere
--- near the next time this player is genuinely shot in the city.
local RETRACT_GRACE_S = 60

--- And how long the PASSIVE listeners may, which is not the same window and
--- must not be. Two things read this: the filed-call listener below, and
--- ArenaDispatch.ShouldSuppressAlert, which a dispatch script asks BEFORE
--- raising an alert at all.
---
--- THE TWO PATHS ARE NOT EXPOSED TO THE SAME THING. The sweep is something
--- the ARENA starts, seconds after a round it ran: it asks for ids it built
--- itself around one player, so sixty seconds of slack costs nothing but a
--- few pointless calls. The filed listener is passive -- it sees every alert
--- filed anywhere on the server, by anybody, about anybody -- so the same
--- sixty seconds means a full minute in which a genuine city call about
--- somebody who has walked out of the arena is silently withdrawn.
---
--- This file's own rule decides it: "a failure to suppress costs an operator
--- an unwanted call-out; a wrong suppression costs somebody a crime nobody
--- was told about." The passive path takes the narrower window.
---
--- Ten seconds, not zero: the alert this is for is one that was already in
--- flight when the fighter left, and sc-dispatch writes it through an awaited
--- oxmysql insert first. Ten covers that several times over.
local FILED_GRACE_S = 10

--- When a withdrawal is asked for, in milliseconds after the first attempt.
---
--- ONE CONSTANT FOR BOTH PATHS, and the comment inside retractFor is the
--- reason it exists at all: sc-dispatch's AddNotification writes the call
--- through oxmysql and AWAITS it before a single EMS screen is told, which
--- is routinely longer than the 250ms pause either path waits. A withdrawal
--- that arrives first withdraws NOTHING -- the UPDATE matches no row, the
--- insert lands afterwards, and the alert stays out.
---
--- The filed path used to ask exactly ONCE, which is the schedule that
--- report ("its not even recalling the alert for a person down") was about.
--- Knowing the exact id makes it certain WHICH call to clear; it says
--- nothing about WHEN that call exists. So both ask on the same widening
--- schedule -- a fast server pays almost nothing, a slow one is still
--- covered three seconds out -- and asking twice costs nothing, because a
--- clear for a call that is already gone matches no row either.
local RETRY_AT = { 0, 500, 1500, 3000 }

local function customConfig()
    return (Config.Dispatch and Config.Dispatch.custom) or {}
end

local function stateKey()
    local key = customConfig().stateBagKey
    return type(key) == 'string' and key ~= '' and key or 'crimsonArena'
end

local function announce(eventName, src, matchId)
    if type(eventName) ~= 'string' or eventName == '' then return end

    -- pcall because this crosses into somebody else's handler: a dispatch
    -- script that throws must not take a match start or a match end down
    -- with it.
    local ok, err = pcall(TriggerEvent, eventName, src, matchId)
    if not ok then
        ArenaLog('a handler for "%s" errored: %s', eventName, tostring(err))
    end
end

--- @param src number
--- @param matchId string
--- @param isFighter boolean? -- true only for somebody PLACED in the round
function ArenaDispatch.Set(src, matchId, isFighter)
    if type(src) ~= 'number' or src <= 0 then return end
    if not Arena.IsKey(matchId) then return end

    -- WHOEVER HOLDS THIS ID NOW OWNS IT. See `dropped` above.
    dropped[src] = nil

    -- WHETHER THIS ONE GETS A GRACE WINDOW WHEN THEY LEAVE, decided here
    -- because here is the only place that knows which of the two they are.
    -- A FIGHTER gets one: the window exists because a round RESOLVES and
    -- takes the flag down before the other script has filed the call for the
    -- body that just fell. A SPECTATOR resolves nothing -- they press stop
    -- and are put back where they were standing -- so a window for them is
    -- pure immunity in the city, renewable for as long as they keep pressing
    -- Watch. Spectators are still flagged WHILE watching, which is what
    -- server/match.lua's sweep is for and is not in question here: their
    -- client is inside the fight and sees every shot of it.
    fighter[src] = isFighter == true

    active[src] = matchId
    Player(src).state:set(stateKey(), { active = true, matchId = matchId }, true)
    announce(customConfig().enterEvent, src, matchId)
end

--- Clears the flag. Deliberately unconditional and idempotent: it is called
--- from every exit path there is -- match end, elimination, leaving, an
--- admin stopping a match, a disconnect, the resource shutting down -- and
--- several of those can happen to the same player in quick succession.
--- A flag that outlives the match it belonged to would suppress that
--- player's alerts for the rest of their session.
--- @param src number
function ArenaDispatch.Clear(src)
    if type(src) ~= 'number' or src <= 0 then return end

    local matchId = active[src]

    -- A GRACE WINDOW IS FOR A FIGHTER WHOSE ROUND RESOLVED, and for nobody
    -- else. Not for a spectator who stopped watching, and never for an id
    -- whose holder has left the server -- see `dropped` and `fighter` above.
    if matchId ~= nil and fighter[src] and not dropped[src] then
        leftAt[src] = os.time()
    end

    active[src] = nil
    fighter[src] = nil

    local ok = pcall(function()
        Player(src).state:set(stateKey(), nil, true)
    end)
    if not ok then
        ArenaDebug('dispatch: could not clear the arena flag for %s -- they are most likely already gone.', tostring(src))
    end

    announce(customConfig().exitEvent, src, matchId)
end

--- Forgets the withdrawal window for a player who has left the server.
---
--- SERVER IDS ARE REUSED, and quickly on a busy box. Without this, a fighter
--- leaving a match and then the server hands their id to the next person to
--- connect -- who, shot in the city and stood up by an admin inside the same
--- minute, would have their REAL ambulance withdrawn on the strength of
--- somebody else's round. The window is short, but the harm is the exact one
--- the gate in RetractCallsFor exists to prevent.
---
--- Registered here rather than added to server/main.lua's playerDropped
--- handler because leftAt is this file's own, and nothing outside it should
--- have to know the table exists.
AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end

    leftAt[src] = nil
    -- THESE TWO ARE EACH SUFFICIENT AND BOTH ARE KEPT. Clearing leftAt alone
    -- is undone moments later by the detach still unwinding inside
    -- server/main.lua's own handler, which reaches Clear with the player
    -- still flagged -- see `dropped` above. Either nilling `fighter` or
    -- latching `dropped` stops that re-stamp on its own; neither is "the one
    -- that works".
    fighter[src] = nil
    dropped[src] = true
end)

-- ======================================================================
-- THIS RESOURCE ASKS THE SERVER FOR NO PERMISSIONS, AND RUNS NO COMMANDS
--
-- A server that lets a resource write its own permissions has no
-- permissions, so this one does not ask for any and has no route that would
-- need them: it runs nothing on the server console and has no client channel
-- for running anything. The medical handoff is events and exports -- things
-- a script publishes on purpose for other scripts to call, needing no
-- permission from anybody. NOTHING CHECKS THIS ANY MORE -- the test that
-- failed the build if any source file reached for the permission natives was
-- retired with the rest of the suite -- so it is on whoever edits this file.
-- ======================================================================

local function downStateConfig()
    return (Config.Dispatch or {}).downState or {}
end

local function clearDownMetadata(src)
    local keys = downStateConfig().keys
    if type(keys) ~= 'table' or #keys == 0 then return 0 end

    if type(ArenaGetPlayer) ~= 'function' then return 0 end

    local player = ArenaGetPlayer(src)
    local functions = player and player.Functions
    if type(functions) ~= 'table' then return 0 end
    if type(functions.SetMetaData) ~= 'function' then return 0 end

    local cleared = 0
    for _, key in ipairs(keys) do
        if Arena.IsKey(key) then
            local current = true
            if type(functions.GetMetaData) == 'function' then
                local ok, value = pcall(functions.GetMetaData, key)
                current = ok and value or false
            end

            if current then
                local ok, err = pcall(functions.SetMetaData, key, false)
                if ok then
                    cleared = cleared + 1
                    ArenaDebug('revive: cleared \'%s\' metadata for %d.', key, src)
                else
                    ArenaLog('revive: could not clear \'%s\' metadata for %d (%s).',
                        key, src, tostring(err))
                end
            end
        end
    end

    return cleared
end

--- Puts the medical script's "this player is down" flags back down, now.
---
--- THE BUG THIS EXISTS TO CLOSE, and it is the one that actually produces
--- the calls an operator sees. The flags were only ever cleared from
--- ArenaDispatch.Revive, and on the path a fighter takes MOST -- dying with
--- lives left -- that runs `respawnDelaySeconds` (5s) plus
--- `afterRespawnDelayMs` (2000ms) after the death. Seven seconds. Against a
--- dispatch client polling that metadata every 500ms, that is fourteen
--- windows: PlayerDown and PlayerDead were not "never raised", they were
--- CERTAIN, on every death of every round, while the config beside them
--- claimed prevention.
---
--- Called at the moment of death rather than at the end of the respawn, and
--- backed by the hold below, the window shrinks from seven seconds to less
--- than one poll.
--- @param src number
--- @return integer cleared
function ArenaDispatch.ClearDownState(src)
    return clearDownMetadata(src)
end

--- HOLDING THEM DOWN, because clearing once is not the same as keeping
--- clear.
---
--- A medical script does not set its flag once and stop. It sets it from the
--- victim's own client at the moment of death, and several of them re-assert
--- it -- on a respawn, on a poll of their own, on a resource restart. One
--- clear at one instant answers one of those. So while a player is in a
--- match the arena re-asserts the answer on its own clock, which is a wall
--- clock and not a race: it does not matter who wrote last, only that the
--- arena writes again within the poll window.
---
--- WHAT IT IS NOT. It is not a guarantee and must never be described as one.
--- A dispatch client polling on its own 500ms timer can still catch the flag
--- inside this interval, and sc-ambulance's own EMSDownAlert is sent from
--- the victim's client back-to-back with the flag it reads, so no
--- server-side clear can arrive before its guard. What this removes is the
--- CERTAIN loss above; what is left is a narrow one.
---
--- Guarded on `active` rather than on a list of its own, so it can never
--- outlive a match: ArenaDispatch.Clear empties that table on every exit
--- path there is, and a flag held down for a player who has gone home is the
--- exact failure Clear was written to prevent.
--- One pass: the flags put back down for everybody currently in a match.
---
--- SEPARATED FROM THE THREAD ON PURPOSE, and for the same reason
--- ArenaAmmo.SweepReturns is: a `while true` loop is not a thing a test can
--- drive, so the loop is one line and the work is a function, and what gets
--- tested is the work.
--- @return integer touched -- players whose flags were actually written
function ArenaDispatch.HoldDownState()
    local touched = 0
    for src in pairs(active) do
        if clearDownMetadata(src) > 0 then touched = touched + 1 end
    end
    return touched
end

CreateThread(function()
    local interval = Arena.ToInt(downStateConfig().holdIntervalMs) or 0
    if interval <= 0 then return end

    while true do
        Wait(interval)
        ArenaDispatch.HoldDownState()
    end
end)

--- CATCHING THE MOMENT ITSELF, instead of finding out on the next sweep.
---
--- THE GAP THE HOLD ABOVE CANNOT CLOSE, measured rather than guessed. The
--- flags this arena keeps down are not written by the medical script an
--- operator installed -- they are written by Qbox's own injury system, in
--- one place:
---
---     AddStateBagChangeHandler(DEATH_STATE_STATE_BAG, nil, function(bagName, _, value)
---         player.Functions.SetMetaData('isdead',      value == deathState.DEAD)
---         player.Functions.SetMetaData('inlaststand', value == deathState.LAST_STAND)
---     end)
---
--- -- qbx_medical/server/main.lua. The metadata is a MIRROR of a state bag,
--- rewritten every time that bag changes.
---
--- And a dispatch script reads that mirror off its OWN client, on its own
--- clock. sc-dispatch polls it every 500ms and alerts on the rising edge, so
--- the only thing that decides whether a fighter going on their side pages a
--- medic is whether that poll lands between the medical script writing true
--- and this resource writing false. Against a 250ms hold that is roughly
--- every other knockdown -- which is exactly what an operator sees: not
--- every time, not never, about half.
---
--- A SHORTER INTERVAL IS NOT THE ANSWER. Halving it halves the odds and
--- doubles the write rate for every fighter in every round, forever, to
--- chase something that is still not zero. The interval is the wrong tool:
--- the flag does not drift, it CHANGES, at an instant this server is told
--- about.
---
--- So this listens for that instant. The same state bag, the same handler
--- mechanism, on the server, filtered to players this arena has a claim on
--- -- and the clear goes out on the tick after the change rather than up to
--- a whole interval later. The window stops being "half a poll" and becomes
--- "one tick plus the trip to the client", which is one to two percent of
--- the same poll rather than fifty.
---
--- WHY THE NEXT TICK AND NOT THIS ONE. Qbox's handler and this one hang off
--- the same bag, and nothing decides which of two handlers runs first. Doing
--- the work inline would win only when this resource happened to be
--- registered second. Deferring by a tick lands after every handler for that
--- change, whichever order they ran in, and costs a frame.
---
--- AND THEN A SHORT BURST, because one write answers one edge and the
--- medical script asserts its state more than once on the way down -- the
--- knockdown, the bleed-out, the death that follows it. The burst covers the
--- transition; the hold above covers the rest of the round.
---
--- WHAT THIS IS STILL NOT. It is not prevention and must never be written
--- down as prevention. The decision is made on the victim's own client,
--- inside a resource this one cannot reach, from a value this one does not
--- own -- and FiveM offers nothing that lets one resource stop another's
--- handler running (its own documentation for CancelEvent says, in as many
--- words, that it "does not stop other event handlers from running"). What
--- is left after this is a narrow window that the retract layer further down
--- is there to clean up after.
--- @param src number
local function burstClearDownState(src)
    local config = downStateConfig()

    local span = Arena.ToInt(config.burstMs)
    if span == nil then span = 600 end
    if span < 0 then span = 0 end
    if span > 5000 then span = 5000 end

    local step = Arena.ToInt(config.burstIntervalMs)
    if step == nil then step = 50 end
    if step < 10 then step = 10 end

    -- BOUNDED BY COUNT AS WELL AS BY CLOCK, and the count is the one that
    -- is load-bearing. A clock is not something this function can assume:
    -- GetGameTimer may be absent, and it may be a constant. Against either,
    -- a loop that ends only when the clock passes a deadline does not end at
    -- all -- it spins the server flat out, forever, in the middle of a
    -- knockdown. The pass count is arithmetic and cannot be argued with.
    local passes = math.floor(span / step) + 1
    if passes < 1 then passes = 1 end
    if passes > 200 then passes = 200 end

    local clock = type(GetGameTimer) == 'function' and GetGameTimer or nil

    CreateThread(function()
        -- Wait(0) rather than a straight call: this is the "next tick" the
        -- note above is about, and it is the whole reason the burst is a
        -- thread instead of a loop.
        Wait(0)

        local deadline = clock and (clock() + span) or nil

        for _ = 1, passes do
            -- RE-CHECKED EVERY PASS, not captured once. A fighter can be
            -- eliminated, leave, or have the whole match stopped under them
            -- inside this window, and a burst that kept writing after that
            -- would be holding a flag down for somebody who has gone back to
            -- the city -- the exact failure ArenaDispatch.Clear exists to
            -- prevent.
            if active[src] == nil then return end
            clearDownMetadata(src)

            if deadline and clock() >= deadline then return end
            Wait(step)
        end
    end)
end

--- Registered only where the runtime and the config both provide for it.
---
--- THREE THINGS CAN BE ABSENT and each reads as "do nothing", never as an
--- error: the native itself (this file is loaded by specs that stub a
--- fraction of the server API), the id lookup that turns a bag name back
--- into a player, and the config naming the bag to watch. An operator whose
--- medical script keeps its state somewhere else simply leaves that name
--- empty and gets the hold above on its own, exactly as before.
--- Call ids with a withdrawal schedule already running against them.
local withdrawing = {}

--- What the edge listener has actually seen, for the report below.
---
--- THE ONE SETTING HERE THAT CANNOT FAIL VISIBLY. `watchStateBag` is a
--- string an operator is invited to change, and a state-bag handler
--- registered for a key nothing ever writes does not error, does not warn
--- and does not log -- it simply never runs. config.lua warns against
--- guessing a name for exactly that reason, and then ships one. So the
--- report says whether the name is doing anything, and an operator can tell
--- a working bag from a plausible one without reading any source.
local downState = { watching = nil, changes = 0, edges = 0, reason = nil }

CreateThread(function()
    local key = downStateConfig().watchStateBag
    if not Arena.IsKey(key) then downState.reason = 'no bag is named in the config' return end
    if type(AddStateBagChangeHandler) ~= 'function' then
        downState.reason = 'this server has no AddStateBagChangeHandler'
        return
    end
    if type(GetPlayerFromStateBagName) ~= 'function' then
        downState.reason = 'this server has no GetPlayerFromStateBagName'
        return
    end

    local keys = downStateConfig().keys
    if type(keys) ~= 'table' or #keys == 0 then
        downState.reason = 'the down-state keys list is empty, which switches the layer off'
        return
    end

    downState.watching = key

    -- WHAT "ALIVE" IS CALLED IN THAT BAG, read from the config rather than
    -- assumed to be 1.
    --
    -- It is 1 on Qbox, whose enum is ALIVE/LAST_STAND/DEAD, and that is the
    -- default. But an operator is invited to name a DIFFERENT bag above, and
    -- a resource that lets you do that while hard-coding what one of its
    -- values means is offering a choice it does not honour. The failure is
    -- silent and it is the wrong way round: on an enum where 1 happens to
    -- mean "down", the arena would skip its burst at exactly the moment the
    -- burst exists for, and the operator would see no change at all.
    local aliveValue = downStateConfig().aliveValue
    if aliveValue == nil then aliveValue = 1 end

    AddStateBagChangeHandler(key, nil, function(bagName, _, value)
        -- ALIVE is the one value that needs nothing doing. The medical
        -- script mirrors it as both flags false, which is what this resource
        -- wants anyway, and reacting to it would mean a burst of writes
        -- every time a fighter is revived.
        --
        -- Compared loosely on purpose: a state bag may carry the value as a
        -- number or as a string depending on what wrote it, and `1` and `'1'`
        -- have to mean the same thing here.
        if value == nil then return end

        -- COUNTED BEFORE THE ALIVE TEST, so the report can tell "the bag is
        -- wrong" from "the bag is right and nobody has gone down yet".
        downState.changes = downState.changes + 1

        if value == aliveValue or tostring(value) == tostring(aliveValue) then return end

        local ok, src = pcall(GetPlayerFromStateBagName, bagName)
        src = ok and Arena.ToInt(src) or nil
        if src == nil or src <= 0 then return end
        if active[src] == nil then return end

        downState.edges = downState.edges + 1
        ArenaDebug('revive: %d went down (%s = %s) -- clearing on the edge.',
            src, tostring(key), tostring(value))
        burstClearDownState(src)
    end)
end)

function ArenaDispatch.Revive(src)
    if type(src) ~= 'number' or src <= 0 then return end

    -- THE ARENA DOES NOT STAND PLAYERS UP HERE, and that is deliberate.
    -- Resurrecting the ped from this function would make it a second writer
    -- for a body the medical script also has an opinion about, racing
    -- whatever that script does next. Two resources arguing over one ped is
    -- not a revive; it is a flicker with a winner.
    --
    -- NOTHING IS LEFT ON THE FLOOR BY LEAVING IT OUT. ClearDeadState already
    -- resurrects in the frame the ped dies -- that is death handling, not a
    -- revive, and it is what keeps the death from registering anywhere at all
    -- -- and the respawn releases that hold and re-applies the loadout, which
    -- starts every life on full health and a full plate by rule. A player is
    -- stood up by the arena's ordinary flow either way.
    --
    -- What this function does is the half the arena genuinely cannot: reach a
    -- MEDICAL SCRIPT's own records, which it cannot see and will not guess at.

    if type(ArenaCompat) == 'table' and type(ArenaCompat.ReviveClientEvents) == 'function' then
        for _, name in ipairs(ArenaCompat.ReviveClientEvents()) do
            TriggerClientEvent(name, src)
            ArenaDebug('revive: also told %s for %d.', name, src)
        end
    end

    TriggerClientEvent('crimson_arena:client:holdVitals', src)

    clearDownMetadata(src)

    -- AND ANY CALL THE DISPATCH SCRIPT HAS ALREADY FILED ABOUT THEM IS
    -- WITHDRAWN, whether or not this resource ever saw it being filed. See
    -- ArenaDispatch.RetractCallsFor -- it is defined further down this file
    -- and resolved when this runs, which is the same way HoldDownState is
    -- reached from the thread above.
    --
    -- HERE BECAUSE THIS IS THE ONE FUNCTION EVERY ARENA DEATH GOES THROUGH.
    -- Every path that puts a fighter down calls it -- the death itself, the
    -- respawn, the elimination, the post-match sweep, an admin revive -- so
    -- an alert filed in the seconds around any of them is caught, and a
    -- fourth code path in somebody else's script that nobody has listed is
    -- caught with them.
    if type(ArenaDispatch.RetractCallsFor) == 'function' then
        ArenaDispatch.RetractCallsFor(src)
    end
end

--- Runs the end-of-match revive against one player and says what happened,
--- as lines.
---
--- A DIAGNOSTIC, AND THE ONLY ADMIN ACTION HERE THAT DELIBERATELY REACHES
--- SOMEBODY WHO IS NOT IN A MATCH. That is its entire purpose: an operator
--- wiring up a medical script needs to see the arena's revive land on a
--- player they can watch, without first putting them through a round. The
--- tablet's own revive button is the opposite -- it refuses anyone not in the
--- match being looked at -- so the two do not overlap and neither can stand
--- in for the other.
---
--- LINES RATHER THAN PRINTS, so the tablet can draw exactly what the console
--- used to. The reading IS the feature: which medical scripts were asked, and
--- what to do when the player is up but something still treats them as dead.
---
--- IT REVIVES. A report that only described what would happen would be worth
--- nothing to the person wiring up a medical script, and the action is the
--- same one every match end performs on every fighter. Admin-gated by its
--- callers, which is where the permission check belongs.
--- @param target integer -- server id
--- @return string[]
function ArenaDispatch.ReviveReport(target)
    target = Arena.ToInt(target) or 0
    if target <= 0 then
        return { 'give a server id -- this runs the end-of-match revive against one player.' }
    end

    -- IS ANYBODY ACTUALLY HOLDING THAT ID? Asked FIRST, and the whole point
    -- of this tool turns on it.
    --
    -- THE DIAGNOSTIC USED TO LIE. Nothing on this path checked that the typed
    -- id belonged to a connected player: Revive answers for any positive
    -- number, clearDownMetadata returns 0 the moment ArenaGetPlayer is nil and
    -- that count is discarded, and TriggerClientEvent to an id nobody holds
    -- reaches nobody and says so to no one. So a mistyped or stale id printed
    -- the identical "done. 12's down metadata was cleared and 1 medical
    -- script(s) were asked to revive them." as a real one -- while the
    -- operator's test player lay on the floor untouched and they went looking
    -- for a catalogue bug that was not there.
    --
    -- This is the ONE tool whose entire output is a diagnosis. A diagnosis
    -- that cannot tell "it worked" from "there was nobody there" is worse than
    -- no tool, because it sends the operator somewhere else.
    local holder = ArenaGetPlayer and ArenaGetPlayer(target) or nil
    if holder == nil then
        return {
            ('nobody on this server is holding server id %d right now, so there was nothing to '
                .. 'revive and NOTHING WAS DONE.'):format(target),
            'check the id on your player list and try again -- a player who reconnects gets a new '
                .. 'one, so an id noted down a few minutes ago is often already stale.',
        }
    end

    local lines = {
        ('running the end-of-match revive against %d. Everything below is what a real match would do.')
            :format(target),
    }

    ArenaDispatch.Revive(target)

    local told = 0
    if type(ArenaCompat) == 'table' and type(ArenaCompat.ReviveClientEvents) == 'function' then
        told = #ArenaCompat.ReviveClientEvents()
    end

    if told > 0 then
        lines[#lines + 1] = ('done. %d\'s down metadata was cleared and %d medical script(s) were asked to revive them.')
            :format(target, told)
        lines[#lines + 1] = ('if %d is up but something still treats them as dead, that script is not in the catalogue in shared/compat/dispatch.lua -- add it there with the revive event it listens for.')
            :format(target)
    else
        lines[#lines + 1] = ('done. %d\'s down metadata was cleared. No medical script was detected on this box, so none was asked to revive them.')
            :format(target)
    end

    return lines
end

function ArenaDispatch.IsPlayerInArena(src)
    return ArenaDispatch.GetPlayerMatchId(src) ~= nil
end

function ArenaDispatch.GetPlayerMatchId(src)
    local id = tonumber(src)
    if not id then return nil end
    return active[id]
end

function ArenaDispatch.GetArenaPlayers()
    local out = {}
    for src, matchId in pairs(active) do out[src] = matchId end
    return out
end

--- THE ONE QUESTION A DISPATCH SCRIPT ACTUALLY WANTS ANSWERED: should this
--- player's alert be raised at all?
---
--- NOT THE SAME QUESTION AS IsPlayerInArena, and the difference is the whole
--- reason this exists. A dispatch script raises its alert from a death, and
--- a death is resolved on a schedule the arena does not control: the round
--- ends, the flag comes down, and MILLISECONDS LATER somebody else's handler
--- files a person-down call for a body that was in the arena when it fell.
--- IsPlayerInArena is honest and says no -- they are not in a match, that is
--- true -- and the alert goes out. This says yes for a short window after
--- they leave, which closes that gap.
---
--- WHY A SEPARATE ANSWER RATHER THAN WIDENING IsPlayerInArena. That one is
--- read by scoreboards, phone apps and anything asking "is this person
--- fighting right now", and yes-after-they-stopped would be a lie to every
--- one of those callers. Two questions, two answers.
---
--- FILED_GRACE_S AND NOT RETRACT_GRACE_S, and getting this wrong was a real
--- defect in this function's first version. The argument is already made in
--- full at the top of this file and it applies here word for word: the sweep
--- may use the wide window because it asks about ids it built itself around
--- one player; a PASSIVE listener that sees every alert filed anywhere on the
--- server, about anybody, may not. This is that passive listener and then
--- some -- a dispatch script asks this BEFORE raising an alert at all, as
--- sc-dispatch does on the shooter's own client -- and it is strictly worse
--- placed than the filed listener, because suppression here is TOTAL. The
--- retract layer files the call and then withdraws it, so a mistake leaves a
--- trace and a medic who saw something flash. A mistake here is a person-down
--- call in the city that never existed. Sixty seconds of that is not a grace
--- window, it is a minute of immunity for anybody who has been near a match.
---
--- AND THE WINDOW IS ONLY EVER OPENED FOR A FIGHTER whose round resolved.
--- ArenaDispatch.Set decides that and says why; a spectator stopping a watch
--- earns nothing here, or the toggle is renewable immunity.
---
--- THE `id <= 0` GUARD IS DEFENSIVE AND NOT TEST-HELD, said plainly rather
--- than left to look load-bearing. Set() already refuses an id of zero or
--- less, so neither table can hold one and both lookups miss anyway.
--- Removing the guard changes no answer this suite can produce. It stays
--- because it costs nothing and because "the console is not a player" is
--- worth saying in the one place somebody reads this function.
--- @param src number
--- @return boolean
function ArenaDispatch.ShouldSuppressAlert(src)
    local id = tonumber(src)
    if not id or id <= 0 then return false end
    if active[id] ~= nil then return true end

    local left = leftAt[id]
    if left == nil then return false end
    return os.time() - left <= FILED_GRACE_S
end

-- THE THREE EXPORTS THAT USED TO BE REGISTERED HERE are in
-- server/exports.lua, with the rest of the public surface. The functions
-- above are unchanged and are what those exports call; only the place they
-- are announced from moved.
--
-- WHY THEY MOVED. exports.lua opens by saying it holds the whole public
-- surface in one file so it can be read in one sitting, and while these three
-- sat here that was not true -- it held the surface minus three, which is the
-- discoverability failure that file exists to prevent. A server owner greps
-- one file, finds some of the answers, and writes their own version of the
-- rest.

-- ======================================================================
-- ROUTING BUCKET ISOLATION
--
-- A routing bucket is a separate network instance: entities and events in
-- one do not replicate to players outside it. Every player in a match is
-- moved into one, which means every OTHER player's client -- and so every
-- dispatch or ambulance script running on one -- is never sent the arena at
-- all. There is nothing for them to detect and therefore nothing to report,
-- and none of it needs a line of cooperation from those scripts. It also
-- keeps passers-by out of a live round and stops arena gunfire being heard
-- across the map.
--
-- WHAT IT CANNOT DO, and this is not a shortcoming that can be engineered
-- away: it cannot hide an arena player's own gunfire from that player's OWN
-- client. A dispatch script polling IsPedShooting on the shooter's machine
-- still sees the shooter shooting. The flag above is the answer for that.
--
-- SERVER-SIDE ONLY, ALWAYS. A bucket is assigned here and never on a
-- client's say-so: a client that could pick its own instance could pick the
-- one a match it is not in is being fought in, which is a spectating cheat
-- and a griefing tool in the same request.
-- ======================================================================

local matchBuckets = {}

local netIdOwners = {}

--- The network id of a player's ped right now, or nil for a player who has
--- gone. Guarded because it is asked on the path of every shot fired on the
--- server, and a player who disconnected mid-burst must not take that path
--- down with them.
--- @param src number
--- @return integer|nil
local function netIdOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotId, netId = pcall(NetworkGetNetworkIdFromEntity, ped)
    if not gotId then return nil end

    netId = tonumber(netId)
    if not netId or netId == 0 then return nil end
    return netId
end

local held = {}

local DEFAULT_FIRST_BUCKET = 4210

local function isolationConfig()
    return (Config.Dispatch and Config.Dispatch.isolation) or {}
end

local function isTruthy(value)
    value = tostring(value):lower()
    return value == 'true' or value == '1' or value == 'yes' or value == 'on'
end

--- The other half, and deliberately not `not isTruthy(...)`: a mode name this
--- file has never heard of is neither a yes nor a no, and must not be read as
--- a refusal.
--- @param value any
--- @return boolean
local function isFalsey(value)
    value = tostring(value):lower()
    return value == 'false' or value == '0' or value == 'no' or value == 'off'
end

--- Whether this server has OneSync on, and in which mode.
---
--- ROUTING BUCKETS REQUIRE ONESYNC, AND THIS RESOURCE NEVER ASKED. With it
--- off, SetPlayerRoutingBucket and the SetRoutingBucket* natives do nothing
--- at all -- no error, no return value, no warning. Every line of the
--- allocation below still runs and still looks right; the players simply are
--- not separated. Two matches at one arena then stand in each other, which
--- is precisely what an operator reported.
---
--- Worse than the failure is that the startup report SAID isolation was on,
--- because it read the config setting rather than the world. A guarantee
--- printed to an operator who does not have it is the defect class this
--- codebase keeps producing.
---
--- Two spellings, because builds differ: modern servers answer the single
--- `onesync` convar ('off' / 'legacy' / 'on' / 'infinity'), older ones the
--- pair below.
---
--- AND A CONVAR BOOLEAN IS NOT THE STRING 'true'. `set onesync_enabled 1` is
--- the spelling half the guides on the internet use, and `yes` and `on` both
--- appear in the wild -- GetConvar hands back whatever the operator typed,
--- verbatim. Comparing against 'true' alone read every one of those as OFF,
--- which switched isolation off on servers that had OneSync running, and did
--- it in the one direction nobody notices: quietly, on a server whose
--- startup line then said so in a report nobody re-reads.
--- @return string mode
local function oneSyncMode()
    if type(GetConvar) ~= 'function' then return 'unknown' end

    -- RETURNED VERBATIM, whatever it says. Some builds answer this one as a
    -- mode name and some as a boolean, and tidying the booleans up here
    -- would put a second opinion about what counts as a no in a second
    -- place -- which is how the older pair below came to disagree with
    -- bucketsAvailable in the first place. One reader decides that, and it
    -- is isFalsey. What this function is for is telling an operator what
    -- their server actually said.
    local mode = GetConvar('onesync', '')
    if mode ~= '' then return mode end

    if isTruthy(GetConvar('onesync_enableInfinity', 'false')) then return 'infinity' end
    if isTruthy(GetConvar('onesync_enabled', 'false')) then return 'legacy' end
    return 'off'
end

local warnedNoOneSync = false

--- SET WHEN THE SERVER HAS BEEN CAUGHT NOT HONOURING A BUCKET, and never
--- cleared while the resource runs.
---
--- THE DEFECT CLASS THIS EXISTS TO END. Everything above this line asks the
--- server a QUESTION -- which convar is set, what mode does it name -- and
--- then trusts the answer for the rest of the run. An operator reported
--- twice that matches were still sharing a world while every one of those
--- questions answered yes, and there was no line anywhere in the resource
--- that could have told them otherwise: the allocation ran, the move ran,
--- the log said the match was instanced, and the players stood in each
--- other. A convar is what the server was CONFIGURED with; whether a routing
--- bucket actually took is a different fact, and the only honest way to
--- learn it is to set one and read it back.
local provenInert = false

local function bucketsAvailable()
    if provenInert then return false end

    local mode = oneSyncMode()
    if not isFalsey(mode) then return true end

    if not warnedNoOneSync then
        warnedNoOneSync = true
        ArenaLog('ISOLATION IS NOT AVAILABLE: this server has OneSync off, and routing buckets need it -- ' ..
            'the natives that instance a match do nothing without it, silently. Matches will be fought in the ' ..
            'open world where every client can see them, and two matches cannot share one arena. Set ' ..
            '`set onesync on` in server.cfg (and restart) to get it back.')
    end
    return false
end

local function isolationEnabled()
    if isolationConfig().enabled == false then return false end
    return bucketsAvailable()
end

local function bucketInUse(bucket)
    for _, allocated in pairs(matchBuckets) do
        if allocated == bucket then return true end
    end
    for _, record in pairs(held) do
        if record.bucket == bucket then return true end
    end
    return false
end

local function currentBucket(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return Arena.ToInt(bucket) or 0
end

local function stillConnected(src)
    if type(GetPlayerName) ~= 'function' then return false end
    local ok, name = pcall(GetPlayerName, src)
    if not ok then return false end
    return type(name) == 'string' and name ~= ''
end

--- Moves one player into a bucket AND PROVES IT LANDED.
---
--- SETTING A ROUTING BUCKET IS NOT A REQUEST. It is a synchronous write to a
--- field the server keeps for that client, so on a server where buckets work
--- the read below always agrees with the write above -- there is no race to
--- lose and no tick to wait for. Which is what makes the disagreement worth
--- acting on: it does not mean "not yet", it means the natives are not doing
--- anything, and every promise this resource makes about instancing is
--- already false.
---
--- WHAT IT DOES WITH THAT. It says so once, loudly, in the operator's console
--- rather than in a debug channel they would have to switch on -- and then it
--- stops claiming isolation for the rest of the run. That second half is the
--- important one: with `provenInert` set, GetBucket answers nil, and the
--- guard in server/match.lua refuses to start a second match at an arena
--- somebody is already fighting in. Two rounds sharing a platform is the
--- symptom an operator sees; refusing the second one is the fallback this
--- codebase already had, and it was never reachable because nothing could
--- tell that it was needed.
--- @param src number
--- @param bucket integer
--- @return boolean landed
local function moveTo(src, bucket)
    pcall(SetPlayerRoutingBucket, src, bucket)

    if currentBucket(src) == bucket then return true end

    -- A player who has gone cannot be moved and cannot be read back, and
    -- neither says anything about whether buckets work here. Asked only
    -- AFTER the reading disagrees, because a move that landed needs no
    -- alibi.
    if not stillConnected(src) then return false end

    provenInert = true
    ArenaLog('ISOLATION IS NOT IN FORCE, AND THIS SERVER JUST PROVED IT: %s was put into routing ' ..
        'bucket %d and the server still reports them in %d. The routing natives are not doing anything ' ..
        'here, so matches are being fought in the open world where every client can see them. The usual ' ..
        'cause is OneSync -- `set onesync on` in server.cfg, then restart -- and the server currently ' ..
        'reports onesync as "%s". Until that is fixed the arena will refuse to start a second match at ' ..
        'an arena somebody is already fighting in, because it can no longer keep the two apart.',
        tostring(src), bucket, currentBucket(src), tostring(oneSyncMode()))
    return false
end

local function configureBucket(bucket)
    local config = isolationConfig()

    SetRoutingBucketPopulationEnabled(bucket, config.populationEnabled == true)

    local mode = config.lockdownMode
    if mode ~= 'strict' and mode ~= 'inactive' then mode = 'relaxed' end
    SetRoutingBucketEntityLockdownMode(bucket, mode)
end

-- ======================================================================
-- EMPTYING A BUCKET, WHICH RELEASING ONE HAS NEVER DONE
--
-- THE DEFECT. A routing bucket loses its PLAYERS when a match ends and
-- nothing else. Entities do not follow the people who made them out of an
-- instance -- they stay in it, unowned and unsimulated, frozen wherever they
-- had got to when the last client left, and they come back the moment
-- somebody is routed in again. Nothing in this resource deleted one: the
-- only entity cleanup that existed anywhere was client/match.lua's
-- clearArenaScenery, and that removes the arena's OWN non-networked floor
-- props on the client that built them.
--
-- And the allocator hands the same number straight back out. GetBucket
-- counts up from firstBucket over the numbers currently in use, so on a
-- server running one round at a time every match at every arena gets 4210 --
-- allocated, released, allocated again -- which is exactly what an operator's
-- log showed. A car spawned in round one is therefore not merely still alive
-- somewhere; it is in the room the next round is instanced into. Reported
-- from a live server and reproduced.
--
-- SCOPED BY BUCKET MEMBERSHIP AND NEVER BY COORDINATES. This is the whole
-- reason the sweep is here rather than a radius test on the client. The
-- skydome is a platform a kilometre up: a vehicle put on it rolls off the
-- edge and falls, and by the end of the round it is hundreds of metres below
-- the arena centre and well outside the boundary radius -- which is precisely
-- the case that was tested and has to work. A bucket is not a place, it is an
-- instance, and the falling car is in 4210 the whole way down. Membership
-- therefore answers "is this the arena's mess" exactly, in three dimensions,
-- with no floor height assumed anywhere and no reach outside the arena
-- possible: an entity in the city is in bucket 0 and is never looked at.
-- ======================================================================

--- Every player the server currently has, or nil for a server that cannot be
--- asked. NIL AND EMPTY ARE DIFFERENT ANSWERS on purpose -- "nobody is here"
--- licenses a sweep and "I do not know who is here" must not.
--- @return string[]|nil
local function connectedPlayers()
    if type(GetPlayers) ~= 'function' then return nil end
    local ok, list = pcall(GetPlayers)
    if not ok or type(list) ~= 'table' then return nil end
    return list
end

--- @param bucket integer
--- @return boolean|nil occupied -- nil when the server could not be asked
local function anybodyStandingIn(bucket)
    local list = connectedPlayers()
    if not list then return nil end

    for _, id in ipairs(list) do
        local src = Arena.ToInt(id)
        if src and currentBucket(src) == bucket then return true end
    end
    return false
end

--- The ped of every connected player, as a set. Belt to the occupancy
--- check's braces: a player's own body is NEVER a leftover, whatever bucket
--- the server thinks it is in.
--- @return table<integer, boolean>
local function playerPeds()
    local peds = {}
    local list = connectedPlayers()
    if not list or type(GetPlayerPed) ~= 'function' then return peds end

    for _, id in ipairs(list) do
        local src = Arena.ToInt(id)
        if src then
            local ok, ped = pcall(GetPlayerPed, src)
            ped = ok and Arena.ToInt(ped) or nil
            if ped and ped ~= 0 then peds[ped] = true end
        end
    end
    return peds
end

--- @return function[]
local function entityPools()
    local pools = {}
    if type(GetAllVehicles) == 'function' then pools[#pools + 1] = GetAllVehicles end
    if type(GetAllObjects) == 'function' then pools[#pools + 1] = GetAllObjects end
    if type(GetAllPeds) == 'function' then pools[#pools + 1] = GetAllPeds end
    return pools
end

--- Whether any match OTHER than this one is using the number.
---
--- With `perMatch` off every match shares one bucket, so a finished round's
--- release names a room another round is still being fought in. Emptying that
--- would delete a live match's vehicles out from under it, which is far worse
--- than the leftover this sweep exists to remove. DO NOT drop this check on
--- the grounds that `perMatch` ships on: it is one line in config.lua.
--- @param bucket integer
--- @param matchId any
--- @return boolean
local function bucketIsSomebodyElses(bucket, matchId)
    for otherId, allocated in pairs(matchBuckets) do
        if allocated == bucket and otherId ~= matchId then return true end
    end
    for _, record in pairs(held) do
        if record.bucket == bucket and record.matchId ~= matchId then return true end
    end
    return false
end

--- Deletes what is left in one arena instance.
---
--- REFUSED, NOT ATTEMPTED-AND-HOPED, on every reading that is not a flat yes:
--- a build with no server-side entity pools, a server that will not say who is
--- connected, a bucket another match is using, and above all a bucket somebody
--- is still standing in. Each of those leaves the leftover alone, which is the
--- safe direction on purpose: a stray car in an instance is a nuisance, and a
--- deleted entity CANNOT be got back.
--- @param bucket integer|nil
--- @param matchId any
--- @return integer removed
function ArenaDispatch.ClearBucket(bucket, matchId)
    bucket = Arena.ToInt(bucket)
    if not bucket or bucket <= 0 then return 0 end
    if type(GetEntityRoutingBucket) ~= 'function' or type(DeleteEntity) ~= 'function' then return 0 end

    local pools = entityPools()
    if #pools == 0 then return 0 end

    if bucketIsSomebodyElses(bucket, matchId) then
        ArenaDebug('dispatch: bucket %d was left as it is -- another match is using the same number.', bucket)
        return 0
    end

    -- NEVER SWEEP A ROOM SOMEBODY IS STANDING IN, and an unanswerable server
    -- counts as occupied. The one way this could cost a player anything is
    -- running while they are in there -- in a vehicle, on foot, stranded by a
    -- restore that did not land -- so it asks the world rather than the
    -- bookkeeping, which is the same lesson EnterBucket's drift repair learnt.
    if anybodyStandingIn(bucket) ~= false then
        ArenaDebug('dispatch: bucket %d was left as it is -- somebody is in it, or the server would not say.', bucket)
        return 0
    end

    local protected = playerPeds()
    local removed, refused = 0, 0

    for _, pool in ipairs(pools) do
        local gotPool, handles = pcall(pool)
        if gotPool and type(handles) == 'table' then
            for _, entity in ipairs(handles) do
                local handle = Arena.ToInt(entity)
                local inHere = handle and not protected[handle]
                    and select(2, pcall(GetEntityRoutingBucket, handle)) == bucket

                if inHere then
                    pcall(DeleteEntity, handle)
                    local stillThere = type(DoesEntityExist) == 'function'
                        and select(2, pcall(DoesEntityExist, handle)) == true
                    if stillThere then refused = refused + 1 else removed = removed + 1 end
                end
            end
        end
    end

    if removed > 0 or refused > 0 then
        ArenaDebug('dispatch: emptied routing bucket %d after match %s -- %d entity(s) removed, %d refused.',
            bucket, tostring(matchId), removed, refused)
    end
    return removed
end

function ArenaDispatch.GetBucket(matchId)
    if not isolationEnabled() then return nil end
    if not Arena.IsKey(matchId) then return nil end

    local existing = matchBuckets[matchId]
    if existing then return existing end

    local config = isolationConfig()
    local bucket = math.max(1, Arena.ToInt(config.firstBucket) or DEFAULT_FIRST_BUCKET)

    if config.perMatch ~= false then
        while bucketInUse(bucket) do bucket = bucket + 1 end
    end

    matchBuckets[matchId] = bucket
    configureBucket(bucket)

    -- SWEPT ON THE WAY IN AS WELL AS ON THE WAY OUT, and this half is
    -- deliberately not the redundant one. Release empties a bucket after a
    -- round this resource saw end; nothing runs after a server crash, a hard
    -- `stop crimson_arena`, or a script error that took the teardown with it
    -- -- and the debris from that run is still sitting in 4210 when the
    -- resource comes back up and allocates 4210 again. This is the only pass
    -- that can ever reach it. It is safe here for the same reason it is safe
    -- there: the number was just chosen BECAUSE no match holds it, and the
    -- occupancy check refuses a room anybody is standing in.
    ArenaDispatch.ClearBucket(bucket, matchId)

    ArenaDebug('dispatch: match %s is instanced in routing bucket %d.', tostring(matchId), bucket)
    return bucket
end

function ArenaDispatch.EnterBucket(src, matchId)
    if type(src) ~= 'number' or src <= 0 then return false end

    local bucket = ArenaDispatch.GetBucket(matchId)
    if not bucket then return false end

    local current = held[src]
    if current then
        if current.bucket == bucket then
            -- OURS ON PAPER IS NOT THE SAME AS ACTUALLY BEING THERE, and
            -- reading the record instead of the world is how isolation goes
            -- quietly missing.
            --
            -- A routing bucket is server-wide state that any resource can
            -- set. An interior, a job, a heist, an admin tool, or simply
            -- another script's own cleanup can move a player out of the
            -- match's instance, and nothing tells this file. The record
            -- still says they are where they belong, so every later pass
            -- agrees there is nothing to do -- and the player fights the
            -- rest of the round in the ordinary world, in front of the
            -- whole server, with the arena's one real defence against
            -- dispatch scripts simply absent.
            --
            -- `previous` is deliberately NOT re-captured. Where they came
            -- from has not changed just because somebody moved them since,
            -- and taking the reading now would record whatever instance
            -- they drifted into as the place to send them home to.
            if currentBucket(src) ~= bucket then
                ArenaDebug('dispatch: %s had drifted out of arena bucket %d -- putting them back.',
                    tostring(src), bucket)
                moveTo(src, bucket)
            end
            return true
        end
        ArenaDispatch.ExitBucket(src)
    end

    local previous = currentBucket(src)

    if bucketInUse(previous) then
        ArenaDebug('dispatch: %s was already sitting in arena bucket %d -- they will be restored to the default world instead.',
            tostring(src), previous)
        previous = 0
    end

    held[src] = { bucket = bucket, previous = previous, matchId = matchId }

    return moveTo(src, bucket)
end

function ArenaDispatch.ExitBucket(src)
    if type(src) ~= 'number' or src <= 0 then return false end

    local record = held[src]
    if not record then return false end
    held[src] = nil

    -- Guarded the way Clear's bag write is: the disconnect path reaches here
    -- after the player has gone, and a native called against an id that no
    -- longer exists must not take the rest of the exit down with it.
    local ok = pcall(SetPlayerRoutingBucket, src, record.previous)
    if not ok then
        ArenaDebug('dispatch: could not restore routing bucket %d for %s -- they are most likely already gone.',
            record.previous, tostring(src))
    end

    -- AND THE WAY OUT IS PROVED, THE SAME WAY THE WAY IN IS.
    --
    -- moveTo reads the bucket back after writing it and says at length why:
    -- setting a routing bucket is a synchronous write to a field the server
    -- keeps for that client, so a disagreement is never "not yet", it is the
    -- write having done nothing. THIS SIDE NEVER ASKED. The pcall above only
    -- ever noticed a THROW, and a call that returns quietly without moving
    -- anybody read here as a clean exit.
    --
    -- WHAT THAT COSTS IS THE WHOLE POINT OF BUCKETS, INVERTED. A player left
    -- in the match's bucket while the rest of the server is in the world is
    -- invisible to every one of them, and every one of them is invisible to
    -- them. They get their own kit back, they are stood at the lobby ped,
    -- their panel works -- and they are alone on the server. Reported off a
    -- live server as players "coming out of the arena invisible", with not
    -- one line in any log, because nothing on this path ever looked.
    --
    -- TRIED AGAIN ONCE FIRST, because the cheapest answer to a write that did
    -- not land is the same write, and a single retry costs nothing on the
    -- overwhelmingly common path where the first one worked and this branch
    -- is never entered at all.
    --
    -- ASKED ONLY OF A PLAYER WHO IS STILL HERE. The disconnect path reaches
    -- this function after the id has stopped meaning anything, and a read
    -- that cannot answer must not be reported as a stranded player.
    if ok and stillConnected(src) and currentBucket(src) ~= record.previous then
        pcall(SetPlayerRoutingBucket, src, record.previous)

        if currentBucket(src) ~= record.previous then
            ArenaLog('dispatch: %s IS STILL IN ROUTING BUCKET %d after being sent back to %d, twice. '
                .. 'THEY ARE INVISIBLE TO EVERYBODY ON THIS SERVER AND EVERYBODY ON IT IS INVISIBLE TO '
                .. 'THEM -- that is what a routing bucket does, and they are still in one. Nothing else '
                .. 'about their exit failed: they have their own kit and they are stood where they '
                .. 'should be. Run /arenaconsole for what the routing natives are actually doing on '
                .. 'this box; the usual cause is OneSync, and the server currently reports it as "%s". '
                .. 'The player can be freed by reconnecting.',
                tostring(src), currentBucket(src), record.previous, tostring(oneSyncMode()))
        end
    end

    ArenaDispatch.ReleaseBucket(record.matchId)
    return true
end

function ArenaDispatch.ReleaseBucket(matchId)
    local bucket = matchBuckets[matchId]
    if not bucket then return false end

    -- Matched on the match id, not the number alone: with `perMatch` off
    -- every match shares one bucket, and another match's fighters standing
    -- in it must not keep this finished match's mapping alive forever.
    for _, record in pairs(held) do
        if record.bucket == bucket and record.matchId == matchId then return false end
    end

    matchBuckets[matchId] = nil

    -- THE NUMBER GOES BACK ON THE SHELF EMPTY, and that is the point of
    -- doing it here rather than in ArenaMatch.End. Every way a round can stop
    -- arrives at this one function -- End, Abort, the last fighter leaving,
    -- an admin stop, a disconnect, the countdown-overrun unwind, and
    -- onResourceStop -- so a sweep on this line runs on all of them and
    -- CANNOT be forgotten by an exit added later. Above the debug line so the
    -- console reads in the order the work happened.
    ArenaDispatch.ClearBucket(bucket, matchId)

    ArenaDebug('dispatch: routing bucket %d released by match %s.', bucket, tostring(matchId))
    return true
end

--- What isolation is ACTUALLY doing right now, for the startup report and
--- for the instancing report.
---
--- Three separate facts, kept separate on purpose, because an operator
--- reading "isolation: off" cannot act on it without knowing which of the
--- three said no.
--- @return table
function ArenaDispatch.IsolationState()
    return {
        wanted = isolationConfig().enabled ~= false,
        oneSync = oneSyncMode(),
        provenInert = provenInert,
        inForce = isolationEnabled(),
        perMatch = isolationConfig().perMatch ~= false,
    }
end

--- Everything the instancing report says, as a list of console-ready lines.
---
--- SPLIT OUT OF THE COMMAND so the admin tablet can show the same reading
--- without an operator having to be at a console to get it. The command
--- below is now nothing but "build this and print it", which is the only
--- way the two can be guaranteed to say the same thing.
--- @return string[]
function ArenaDispatch.IsolationReport()
    local lines = {}
    local function say(fmt, ...)
        local ok, text = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and text or fmt
    end

    local state = ArenaDispatch.IsolationState()
    say('config says %s, server reports onesync "%s", a move has %sbeen caught not landing.',
        state.wanted and 'ON' or 'OFF', tostring(state.oneSync), state.provenInert and '' or 'NOT ')
    say('isolation is %s right now, %s.',
        state.inForce and 'IN FORCE' or 'NOT IN FORCE',
        state.perMatch and 'one bucket per match' or 'one bucket shared by every match')

    local matches = 0
    for matchId, bucket in pairs(matchBuckets) do
        matches = matches + 1
        say('  match %s was allocated bucket %d.', tostring(matchId), bucket)
    end
    if matches == 0 then
        say('  no match holds a bucket at the moment.')
    end

    local players = 0
    for player, record in pairs(held) do
        players = players + 1
        local actually = currentBucket(player)
        say('  %s (match %s) should be in %d and the server says %d%s',
            tostring(player), tostring(record.matchId), record.bucket, actually,
            actually == record.bucket and '.' or '  <-- NOT INSTANCED')
    end
    if players == 0 then
        say('  nobody is being held in an arena bucket.')
    end

    -- AND EVERY CONNECTED PLAYER, WHETHER THIS RESOURCE KNOWS THEM OR NOT.
    --
    -- THE BLIND SPOT THIS FILLS, and it is the one an operator runs this
    -- command to see. The loop above walks `held`, so it reports the players
    -- the arena is deliberately keeping in an instance -- and the player who
    -- matters is the one who is NOT in it. A fighter left in an arena bucket
    -- with no record is invisible to every check this file makes, including
    -- ExitBucket's own read-back, which returns early for anybody it has no
    -- record of. `held` is memory, so a resource restart empties it while the
    -- buckets it wrote stay exactly where they were.
    --
    -- WHAT IT IS FOR, in the operator's words: "I am not invisible in my
    -- eyes but the other person is", and a relog fixes it. Two players in
    -- two different buckets is precisely that -- each sees themselves, both
    -- are invisible to the other -- and a reconnect clears it because a
    -- routing bucket does not survive one. The whole roll-call is reported
    -- rather than only the odd ones out, because who can see whom is decided
    -- by the WHOLE set and a line saying "player 4 is in 4210" means nothing
    -- until you can see that player 2 is in 0.
    local list = connectedPlayers()
    if not list then
        say('  this server would not say who is connected, so the roll-call below '
            .. 'cannot be taken. That is the reading, not a failure of the arena.')
        return lines
    end

    local occupied, stranded, counted = {}, 0, 0

    for _, id in ipairs(list) do
        local player = Arena.ToInt(id)
        if player then
            counted = counted + 1
            local bucket = currentBucket(player)
            occupied[bucket] = (occupied[bucket] or 0) + 1

            local name = type(ArenaPlayerName) == 'function'
                and ArenaPlayerName(player) or tostring(player)
            local note = ''
            if bucket ~= 0 and not held[player] then
                stranded = stranded + 1
                note = '  <-- STRANDED: the arena has NO RECORD of putting them there, so nothing '
                    .. 'here will ever take them out. They can be freed by reconnecting.'
            end

            say('  %s (%s) is in bucket %d%s', tostring(player), name, bucket, note)
        end
    end

    local rooms = 0
    for _ in pairs(occupied) do rooms = rooms + 1 end

    if counted == 0 then
        say('  nobody is connected.')
    elseif rooms > 1 then
        say('%d player(s) are spread across %d DIFFERENT routing buckets. '
            .. 'Anybody in one cannot see anybody in another, and each of them can still see '
            .. 'THEMSELVES -- which is what "everyone else is invisible" looks like from inside. '
            .. 'If a match is live that is correct and expected; if no match is live, it is not.',
            counted, rooms)
    else
        say('all %d connected player(s) are in the same bucket, so routing '
            .. 'is not what is hiding anybody from anybody.', counted)
    end

    if stranded > 0 then
        say('%d player(s) are STRANDED in an arena bucket with no record. '
            .. 'That is a defect in this resource and worth reporting -- the usual cause is the '
            .. 'resource being restarted while they were in a round.', stranded)
    end

    return lines
end

--- THE DISPATCH COMPAT REPORT, reachable from the admin tablet.
---
--- shared/compat/dispatch.lua builds the whole block -- which police and EMS
--- resources are actually running on THIS server, which of them the arena can
--- mute on its own, and the exact line to paste into the ones it cannot. It
--- already prints twice: once on resource start, and again on /arenadispatch.
--- Both of those go to the SERVER CONSOLE. An operator who runs the server
--- from a panel, or who is in-game when the alert fires, sees neither -- and
--- in-game /arenadispatch answers with the whole report crushed into a single
--- notification toast, which is not something anyone can read a resource name
--- out of.
---
--- So this accessor hands the same lines to the tablet's Tools tab, where
--- they are a scrollable report like Instancing and Opening hours already
--- are. Same text, same order, same source -- only the way out is new.
---
--- Why the operator needs it at all: the retract layer clears an EMS call
--- AFTER it is filed, so the alert still lands on a medic's screen for the
--- second or two before it goes. This report is the only thing that names
--- WHICH of their scripts still needs the state-bag line pasted into it.
--- @return string[]
--- One line saying what the edge listener is doing, if anything.
---
--- APPENDED ON EVERY PATH, including the ones where the compat layer is
--- missing or broken. It is about a setting inside THIS resource rather than
--- about the scripts around it, so none of the compat layer's failures say
--- anything about whether it is working -- and an operator reading a report
--- that opens with "this build has no dispatch compat report" is exactly the
--- one who needs to know the other half is still running.
local function downStateLine()
    if downState.watching == nil then
        return ('down-state edge clearing is OFF -- %s.')
            :format(downState.reason or 'the layer did not start')
    end

    if downState.changes == 0 then
        return ('down-state edge clearing is watching "%s" and that bag has NEVER changed. '
            .. 'Either nobody has gone down yet, or the name is wrong -- a bag nothing writes '
            .. 'cannot tell you which, so check it against your medical script if alerts are '
            .. 'still getting out.'):format(downState.watching)
    end

    return ('down-state edge clearing is watching "%s": %d change(s) seen, %d of them a fighter '
        .. 'going down and cleared on the edge.')
        :format(downState.watching, downState.changes, downState.edges)
end

--- What sc-dispatch's OWN arena integration is doing, and whether this
--- resource is holding up its end of it.
---
--- THIS USED TO REPORT ON A BLOCK WE SHIPPED. A retired document asked an
--- operator to paste ~230 lines into the bottom of sc-dispatch/server/main.lua,
--- and this line asked that block to answer for itself. Both are gone, and
--- DISPATCH-ALERTS.md keeps the story under "What used to be here": the block
--- never installed, because an export resolved through TriggerEvent arrives as
--- a msgpack FUNCREF TABLE rather than a function, so its
--- `type(original) ~= 'function'` gate took the bail-out every time. Its own
--- tests passed because the harness handed the callback a raw Lua closure
--- instead of round-tripping it the way the runtime does. sc-dispatch ships
--- the integration itself now.
---
--- WHAT HE BUILT IS BETTER THAN WHAT WE HAD. His check runs on the shooter's
--- OWN CLIENT and stops the alert being RAISED -- shots fired, person down,
--- person dead, and the manual "press G for help" call, which nothing on our
--- side ever reached. Ours cancelled the packet after the fact.
---
--- SO ALL THIS RESOURCE OWES IT IS THE TWO THINGS IT READS, and this line
--- says whether both are true:
---
---   1. `LocalPlayer.state.crimsonArena.active` -- the replicated bag, which
---      ArenaDispatch.Set writes for fighters AND spectators.
---   2. `exports['Crimson-Arena']:IsInArena()` -- the client export, which is
---      the fighter-only fallback he tries when the bag is empty.
---
--- @return string
--- sc-dispatch'S OWN SWITCH, AS A VERDICT RATHER THAN AS PROSE.
---
--- SPLIT OUT BECAUSE THE REPORT WAS ANSWERING THE SAME QUESTION TWICE AND
--- DISAGREEING WITH ITSELF. alertGuardLine below reads this switch and, when
--- it is on, tells the operator in as many words that "no arena shot, death
--- or help-call is paged". The TABLE at the top of the same report is built
--- by shared/compat/dispatch.lua's statusOf, which knew only two ways a
--- resource can be handled -- a mute this resource carries, or a
--- disableExports call -- and had never heard of sc-dispatch asking US.
---
--- So a correctly integrated server was shown, in one report:
---     sc-dispatch          police+EMS  NOT muted -- needs the line below
--- directly above a paragraph saying it was muted. Worse than cosmetic: that
--- row is also what raises `unhandled`, which is what suppresses the "wired"
--- verdict -- so the false row also printed a paste-this-line block the
--- operator did not need and put a caveat on the isolation line that was not
--- true. One wrong answer, three wrong pieces of advice. Reported by an
--- operator whose dispatch was, in fact, silent.
---
--- READ, NEVER WRITTEN, and unknown-safe: see the file-reading note in the
--- body. nil means "could not tell", which is NOT the same as false and must
--- never be reported as one.
--- @return boolean|nil on -- true, false, or nil when it could not be read
local function scDispatchIntegrationOn()
    -- HIS `Integrations` TABLE IS A TABLE IN HIS LUA STATE -- nothing to do
    -- with this resource's own settings, and deliberately not written here as
    -- a dotted name, because tools/verify_contracts.py reads every such name
    -- in this tree as a setting THIS resource must define. There is no export
    -- for it either, so this reads the file he ships unencrypted and looks
    -- for the assignment.
    local read, body = pcall(LoadResourceFile, 'sc-dispatch', 'config.lua')
    if not read or type(body) ~= 'string' then return nil end

    -- LINE BY LINE, WITH TRAILING COMMENTS CUT OFF, because a match run over
    -- the whole file reads a COMMENTED-OUT example as the live setting.
    -- sc-dispatch's config ships the block commented out above the real one
    -- on some builds, and a whole-file match found the example's
    -- `CrimsonArena = true` and reported the integration ON while the live
    -- line underneath said false. That is the dangerous direction: an
    -- operator told it is working stops looking.
    --
    -- The first LIVE assignment wins. A long-bracket comment would still fool
    -- this; that is the honest limit of reading a file you do not parse, and
    -- it is why the nil answer exists.
    for line in body:gmatch('[^\n]+') do
        local value = line:gsub('%-%-.*$', ''):match('CrimsonArena%s*=%s*([%a]+)')
        if value == 'true' then return true end
        if value == 'false' then return false end
    end

    return nil
end

--- WHAT THE COMPAT TABLE SHOULD SAY ABOUT EACH DETECTED RESOURCE, for the
--- rows shared/compat/dispatch.lua cannot work out on its own.
---
--- ONLY POSITIVE, CONFIRMED MUTES GO IN HERE. A resource this cannot vouch
--- for is left out entirely, so the table falls back to its own reading and
--- keeps saying NOT muted -- which is the safe direction. In particular
--- sc-police and sc-ambulance are NOT listed: sc-dispatch's switch is its own
--- integration and says nothing about what those two raise directly. See
--- ambulanceGuardLine for why that distinction is load-bearing.
--- @return table<string, table>
local function compatIntegrations()
    local out = {}

    local known, state = pcall(GetResourceState, 'sc-dispatch')
    if known and state == 'started'
        and stateKey() == 'crimsonArena'
        and scDispatchIntegrationOn() == true
    then
        out['sc-dispatch'] = {
            muted = true,
            note = 'muted by its own integration -- Integrations.CrimsonArena = true in sc-dispatch/config.lua',
        }
    end

    return out
end

local function alertGuardLine()
    local known, state = pcall(GetResourceState, 'sc-dispatch')
    if not known or state ~= 'started' then
        return 'sc-dispatch is not running, so its arena integration is not this box\'s route to '
            .. 'a quiet dispatch. The layers above are what is keeping alerts down here.'
    end

    -- THE KEY HE READS IS HARD-CODED ON HIS SIDE, and this is the one way an
    -- operator can break the integration from OUR config without being told.
    --
    -- He reads `LocalPlayer.state.crimsonArena` by that literal name. Rename
    -- stateBagKey here and the bag he looks for is never written -- and the
    -- export he falls back to answers only for FIGHTERS, because a spectator
    -- never calls ArenaDispatch.Enter on their own client. So the hole a
    -- rename opens is precisely the watchers: people sitting in the arena
    -- with a camera up, raising shots-fired and person-down calls about a
    -- round they are not even in.
    local key = stateKey()
    if key ~= 'crimsonArena' then
        return ('sc-dispatch is running, but Config.Dispatch.custom.stateBagKey here is "%s" and '
            .. 'sc-dispatch reads "crimsonArena" by that exact name. Fighters are still covered '
            .. 'by the export it falls back to; SPECTATORS ARE NOT, because that export only '
            .. 'answers for somebody actually placed in a round. Put the key back to '
            .. '"crimsonArena" or expect watchers to page EMS from inside the arena.')
            :format(tostring(key))
    end

    -- HIS SWITCH, READ OFF HIS OWN CONFIG FILE -- see scDispatchIntegrationOn.
    -- ONE READER, SHARED WITH THE TABLE ABOVE. It used to be inlined here,
    -- which is how the row and this paragraph came to disagree.
    local settingSays = scDispatchIntegrationOn()

    if settingSays == true then
        return 'sc-dispatch is running with Integrations.CrimsonArena = true in its own config, '
            .. 'so it asks '
            .. 'this resource before raising an alert and no arena shot, death or help-call is '
            .. 'paged. Fighters answer through the state bag and the client export; spectators '
            .. 'through the bag.'
    end

    if settingSays == false then
        return 'sc-dispatch is running but Integrations.CrimsonArena in its own config is FALSE, '
            .. 'so it '
            .. 'never asks this resource and every arena shot and death is paged as an ordinary '
            .. 'city call. Set it to true in sc-dispatch/config.lua -- nothing needs changing '
            .. 'here.'
    end

    return 'sc-dispatch is running. Its config could not be read from here, so check '
        .. 'Integrations.CrimsonArena is true in sc-dispatch/config.lua -- that switch is '
        .. 'what makes it ask this resource before paging anybody. Nothing needs changing here.'
end

--- WHETHER sc-ambulance'S TWO ALERT HANDLERS HAVE AN ARENA GUARD IN THEM.
---
--- sc-ambulance SHIPS NO ARENA INTEGRATION AT ALL. Not a mention of this
--- resource, a state bag, a combat zone or a paintball check anywhere in it --
--- and once sc-dispatch's own integration is switched on, this is the one
--- real hole left. Its client raises `hospital:server:EMSDownAlert` from two
--- places and `hospital:server:ambulanceAlert` from three, and the server
--- handler for each pages every on-duty medic.
---
--- NEITHER IS COVERED BY sc-dispatch'S OWN INTEGRATION, and the two are not
--- equally bad. Worth having straight, because the obvious reading gets it
--- backwards.
---
--- EMSDownAlert calls sc-dispatch's SERVER export. sc-dispatch's integration
--- is a CLIENT check -- it runs on the player's own machine before an alert
--- is raised -- so a call arriving at its server export has already gone
--- round it, and turning that integration on does not touch this path. BUT
--- the call does not stand: AddNotification announces the whole payload on
--- `sc-dispatch:server:witnessForward` before it writes a row, the retract
--- layer in this file is listening on exactly that event, and the payload
--- sc-ambulance builds carries `caller_source`. So this one is raised and
--- then WITHDRAWN a quarter of a second later. A medic on duty at that
--- instant still sees it flash; nothing persists.
---
--- ambulanceAlert never touches sc-dispatch at all -- the handler loops the
--- on-duty medics and TriggerClientEvents each of them directly. There is no
--- call id, no filed announcement and NOTHING TO WITHDRAW. That hole is
--- permanent until the paste is in.
---
--- BUT IT IS DORMANT ON THE SHIPPED CONFIG, and saying so is the difference
--- between an operator fixing what is happening and fixing what is not. All
--- three of its live call sites are the ELSE branch of a check on
--- MDTIntegration.Enabled and DisableDefaultAlerts, both of which sc-ambulance
--- ships true, so with sc-dispatch running EMSDownAlert is the only one of the
--- two that ever fires. ambulanceAlert wakes up the day somebody turns one of
--- those off or sc-dispatch stops -- and then it is the un-withdrawable one.
--- Both handlers want the paste; only one of them is paging medics today.
---
--- THREE MORE ambulanceAlert SITES ARE IN client/qbx_medical_compat.lua, which
--- is NOT in sc-ambulance's fxmanifest and is never loaded. They are counted
--- nowhere here for that reason, and the same paste covers them if a future
--- version adds the file.
---
--- Config.Dispatch.custom.cancelEvents CANNOT COVER IT EITHER, for the reason
--- the list itself now gives where it names these two events: sc-ambulance
--- never calls WasEventCanceled(), so raising the cancelled flag changes
--- nothing about what it does next. Two lines in its own server/main.lua are
--- the only thing that works, and DISPATCH-ALERTS.md spells them out.
---
--- SO THIS ANSWERS "DID THE PASTE TAKE" WITHOUT DYING IN THE ARENA TO FIND
--- OUT. It reads the file sc-ambulance ships, finds each handler, and looks
--- for a mention of this resource's name inside that handler's own body. A
--- read, never a write, and never a call into another resource.
---
--- EACH HANDLER IS JUDGED ON ITS OWN BODY AND NOT ON THE FILE. The two sit a
--- dozen lines apart, so a window measured only in characters runs out of one
--- handler and into the next -- which would report an unguarded
--- `ambulanceAlert` as guarded on the strength of the guard in `EMSDownAlert`
--- below it. The window stops at the handler's own `end)` for that reason,
--- and at the next registration after it, whichever comes first.
---
--- IT REPORTS WHAT IT SAW AND NEVER GUESSES. A file it cannot read, a build
--- whose handlers are written some other way, a resource that is not running
--- -- each of those comes back as its own answer, because an operator told
--- the guard is in when it is not stops looking.
---
--- /311 IS NOT JUDGED HERE. sc-ambulance also lets a player type `/311` to
--- page EMS, which works from inside the arena like anywhere else. It is a
--- deliberate act rather than something a fighter's death does to them, so
--- guarding it is optional and DISPATCH-ALERTS.md files it that way. This line
--- speaks only for the two handlers, and says so.
--- @return string
local function ambulanceGuardLine()
    local known, state = pcall(GetResourceState, 'sc-ambulance')
    if not known or state ~= 'started' then
        return 'sc-ambulance is not running, so its medical alert handlers are not a hole on '
            .. 'this box.'
    end

    local read, body = pcall(LoadResourceFile, 'sc-ambulance', 'server/main.lua')
    if not read or type(body) ~= 'string' or body == '' then
        return 'sc-ambulance is running but its server/main.lua could not be read from here, so '
            .. 'whether the arena guard is in its alert handlers is unknown. DISPATCH-ALERTS.md '
            .. 'has the two lines and where they go.'
    end

    -- THE EXACT SHAPE OR NOTHING. A handler written some other way is reported
    -- as not found rather than searched for loosely, because the whole value
    -- of this line is that a "guarded" reading can be trusted.
    --
    -- EVERY REGISTRATION, NOT THE FIRST. Nothing stops a resource registering
    -- the same net event twice -- a compat shim, a second file, a merge that
    -- duplicated a block -- and both handlers run. Taking only the first would
    -- report 2 of 2 with a second, wide-open registration sitting further down
    -- the file paging every medic. All of them have to carry it.
    local function handlerPositions(name)
        local out = {}
        for _, quote in ipairs({ "'", '"' }) do
            local needle = 'RegisterNetEvent(' .. quote .. name .. quote
            local from = 1
            while true do
                local at = body:find(needle, from, true)
                if not at then break end
                out[#out + 1] = at
                from = at + 1
            end
        end
        table.sort(out)
        return out
    end

    -- THE NEXT HANDLER IS THE EDGE, AND THE CHARACTER COUNT IS ONLY A
    -- BACKSTOP. Both facts are load-bearing and the first one carries the
    -- correctness on its own.
    --
    -- The two handlers sit 499 characters apart in the file sc-ambulance
    -- ships, and the guard this resource asks for lands about 90 characters
    -- into the second one. A window measured only in characters therefore has
    -- to be under ~590 to stay out of it -- and the first version of this
    -- function used 600, which is INSIDE that and passed its own test purely
    -- because the 601st character fell in the middle of the word it was
    -- looking for. Ten characters of accident is not a gate. So the window
    -- stops at the handler's own end, and the count is deliberately set far
    -- ABOVE any real gap so that it decides nothing on a file this check can
    -- read at all. guardedAt below has the three edges and why each is there.
    --
    -- THE KEY AS WELL AS THE NAME. A guard written the way this resource's own
    -- config.lua suggests -- `if Player(src).state.crimsonArena then return
    -- end` -- never says "Crimson-Arena" at all, and reporting that working
    -- guard as a definite hole would send an operator to re-paste something
    -- they had already done right. The configured key counts too.
    --
    -- BUT ONLY WHERE A STATE BAG IS BEING READ, which is why this is "state."
    -- and the key rather than the key on its own. stateBagKey is whatever the
    -- operator types: nothing stops it being `src`, `active` or `s`, and a
    -- bare substring search for one of those matches `local src = source` --
    -- a line BOTH of sc-ambulance's handlers already have. A short key would
    -- have reported a completely unguarded resource as fully covered, which
    -- is the one answer this line must never give by accident.
    local keyRead = 'state.' .. stateKey()

    local function guardedAt(at)
        -- THREE EDGES, NEAREST WINS, and the character count is the weakest of
        -- the three. The next RegisterNetEvent is where the NEXT handler
        -- starts, but the handler being judged ends before that -- at its own
        -- `end)` -- and the gap between them holds ordinary file comments. A
        -- window that ran to the next registration would count a mention
        -- sitting in that gap as a guard inside the handler above it.
        --
        -- THE CLOSER IS MATCHED WITH ITS INDENT, and the version that did not
        -- was wrong in a way that gave the one answer this line must never
        -- give by accident. It looked for a literal "\nend)" -- an `end)` at
        -- COLUMN ZERO -- so the moment a registration is wrapped in anything,
        -- that edge silently disappeared:
        --
        --     if MDTIntegration and MDTIntegration.Enabled then
        --         RegisterNetEvent('hospital:server:EMSDownAlert', function(street)
        --             ...
        --         end)
        --     end
        --
        -- That is ordinary Lua, and sc-ambulance's own handler invites it --
        -- its first line is a test on exactly that setting, so hoisting the
        -- test around the registration is the obvious edit. (The setting is
        -- on THEIR Config table, and is deliberately not written here as a
        -- dotted Config name: tools/verify_contracts.py reads every such name
        -- in this tree as a setting THIS resource must define, and has now
        -- caught two of somebody else's.) With the closer
        -- indented, and no further registration below it, BOTH strong edges
        -- were gone and the character count ran 2000 bytes into the tail of
        -- the file. Any unrelated mention down there -- a cached export, a
        -- config table, a compat block -- and a wide-open person-down handler
        -- was reported as carrying a guard.
        --
        -- So the count decides nothing on any file this check can read, which
        -- is what the sentence that used to stand here claimed without it
        -- being true. It is a backstop against a runaway search, nothing more.
        local stop = at + 2000
        -- #'RegisterNetEvent' == 16, so this starts past the one we are in.
        local nextAt = body:find('RegisterNetEvent', at + 16, true)
        if nextAt and nextAt < stop then stop = nextAt end
        local endAt = body:find('\n%s*end%)', at)
        if endAt and endAt < stop then stop = endAt end

        -- A COMMENT IS NOT A GUARD, and this is the trap the shape of our own
        -- paste sets. DISPATCH-ALERTS.md asks the operator to paste a comment
        -- line NAMING this resource directly above the two working lines. A
        -- check that only looked for the name anywhere in the handler would
        -- therefore answer "guarded" for a handler holding the comment and
        -- nothing else -- which is exactly the state somebody leaves it in
        -- while debugging their ambulance script, or after a bad merge takes
        -- the working lines and leaves the comment. They would be told 2 of 2
        -- while every arena death paged every medic.
        --
        -- So each line has its trailing comment cut off before it is read.
        -- A whole-line comment collapses to whitespace and matches nothing;
        -- `exports['Crimson-Arena']...` survives with its own trailing note
        -- removed. It is not a Lua parser and does not need to be: a long
        -- bracket comment or a string holding the name are not states any
        -- paste this document asks for can produce.
        for line in body:sub(at, stop):gmatch('[^\n]+') do
            local code = line:gsub('%-%-.*$', '')
            if code:find('Crimson%-Arena') or code:find(keyRead, 1, true) then return true end
        end
        return false
    end

    local names = { 'hospital:server:ambulanceAlert', 'hospital:server:EMSDownAlert' }
    local missing, unfound, guarded = {}, {}, 0

    for _, name in ipairs(names) do
        local positions = handlerPositions(name)
        if #positions == 0 then
            unfound[#unfound + 1] = name
        else
            -- ALL OF THEM OR NONE. One guarded registration and one open one
            -- is an open handler, and reporting it as covered is the reading
            -- that stops an operator looking.
            local all = true
            for _, at in ipairs(positions) do
                if not guardedAt(at) then all = false end
            end
            if all then guarded = guarded + 1 else missing[#missing + 1] = name end
        end
    end

    if #unfound > 0 then
        -- WORDED TO READ CORRECTLY FOR ONE HANDLER AND FOR TWO. The obvious
        -- phrasing -- "%d of its handlers are not written ..." -- says "1 ...
        -- are" on the commoner of the two cases. These lines are read off a
        -- panel by somebody already unsure whether their server is broken.
        return ('sc-ambulance is running but this check cannot find %d of its expected alert '
            .. 'handlers (%s) written the way it reads them, so the guard cannot be confirmed '
            .. 'from here. DISPATCH-ALERTS.md has the two lines and where they go.')
            :format(#unfound, table.concat(unfound, ', '))
    end

    if #missing > 0 then
        -- "there is NO arena guard in X" rather than "X has NO arena guard in
        -- it", for the same reason as above: the second reads "A and B has"
        -- whenever both handlers are missing it, which is the state every
        -- server starts in.
        return ('sc-ambulance is running and there is NO arena guard in %s, so an arena death '
            .. 'still pages every on-duty medic. Neither sc-dispatch\'s integration nor '
            .. 'cancelEvents can cover this -- DISPATCH-ALERTS.md has the line to paste.')
            :format(table.concat(missing, ' and '))
    end

    return ('sc-ambulance is running and both of its alert handlers (%d of %d) carry an arena '
        .. 'guard, so arena deaths and help-calls are not paged. Its /311 command is not '
        .. 'checked here and is not guarded by default.'):format(guarded, #names)
end

function ArenaDispatch.CompatReport()
    local out = {}

    if type(ArenaCompat) ~= 'table' or type(ArenaCompat.Report) ~= 'function' then
        out[1] = 'this build has no dispatch compat report.'
        out[2] = downStateLine()
        out[3] = alertGuardLine()
        out[4] = ambulanceGuardLine()
        return out
    end

    local ok, lines = pcall(ArenaCompat.Report, compatIntegrations())
    if not ok or type(lines) ~= 'table' then
        out[1] = 'the dispatch compat report could not be taken: ' .. tostring(lines)
        out[2] = downStateLine()
        out[3] = alertGuardLine()
        out[4] = ambulanceGuardLine()
        return out
    end

    for _, line in ipairs(lines) do out[#out + 1] = tostring(line) end
    if #out == 0 then out[1] = 'the dispatch compat report came back empty.' end

    out[#out + 1] = downStateLine()
    -- APPENDED ON EVERY PATH ABOVE TOO, for downStateLine's reason: it is
    -- about a paste into somebody else's file rather than about this build,
    -- so a compat layer that failed says nothing about whether it happened.
    out[#out + 1] = alertGuardLine()
    out[#out + 1] = ambulanceGuardLine()
    return out
end

-- `/arenaisolation` USED TO BE REGISTERED HERE and is not a command any
-- more. The reading it printed is ArenaDispatch.IsolationReport above, which
-- the admin tablet draws under Tools and `/arenaconsole` prints at a
-- console -- the same lines from the same function, through the one command
-- this resource still registers.

-- THE HANDLER THAT MATTERS MOST IN THIS FILE.
--
-- Two things must not survive this resource going away, and the second one
-- is the worse of the two by a distance.
--
-- The flag, because a dispatch script that outlives a restart would keep
-- reading a stale bag and keep suppressing alerts for players standing in
-- the middle of town.
--
-- And THE ROUTING BUCKETS. A bucket lives in the server, not in this
-- resource: stopping crimson_arena does not empty one. A player left behind
-- in an arena instance is alone in an invisible copy of the map -- no other
-- players, no traffic, nobody able to see them -- and there is nothing they
-- can do about it, because the only code that knows which bucket they came
-- from is the code that has just stopped. They cannot fix it, an admin
-- cannot easily see it, and reconnecting does not clear it. So every player
-- this file has moved goes back to the bucket it captured for them, first,
-- unconditionally, and before anything else in the shutdown can fail.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    local restored = 0
    for src in pairs(held) do
        if ArenaDispatch.ExitBucket(src) then restored = restored + 1 end
    end
    if restored > 0 then
        ArenaLog('stopping: returned %d player(s) to the routing bucket they came from.', restored)
    end

    -- AND THEN THE ROOMS THEMSELVES, which the loop above only reaches
    -- through a player. A match whose fighters had all disconnected still
    -- holds its number with nobody left to release it, and a bucket left
    -- full is the leftover an operator sees in the NEXT round -- the same
    -- number is allocated again on the way back up. The players are already
    -- home by this line, so every one of these rooms is empty of people.
    -- Assigning nil to a field during pairs() is defined and adding one is
    -- not, so ReleaseBucket must not grow a path that allocates.
    for matchId in pairs(matchBuckets) do
        ArenaDispatch.ReleaseBucket(matchId)
    end

    for src in pairs(active) do
        ArenaDispatch.Clear(src)
    end
end)

-- ======================================================================
-- BEST-EFFORT EVENT CANCELLING (Config.Dispatch.custom.cancelEvents)
--
-- THE WEAKEST LAYER IN THIS RESOURCE, AND IT IS LABELLED THAT WAY EVERYWHERE
-- IT APPEARS. An operator names the events their dispatch or ambulance script
-- raises to send an alert; this registers a handler on each and calls
-- CancelEvent() when it can establish that the alert is about somebody who is
-- in a match right now.
--
-- WHY IT IS ONLY BEST EFFORT, stated here as bluntly as config.lua states it.
-- CancelEvent() raises a flag and nothing else. The alert is still sent unless
-- the code that raised the event checks WasEventCanceled() afterwards and
-- decides to drop it, AND MANY SCRIPTS NEVER CHECK. On top of that, a script
-- that checks inside its own handler only sees the flag if this resource's
-- handler was registered first -- which is decided by resource start order in
-- server.cfg, and no resource can guarantee that about another. An operator
-- who leaves this list as their only integration should assume their alerts
-- are still going out. The state bag above is one line in the sending script
-- and it always works; this is for the case where that script cannot be
-- edited at all.
--
-- WHY IT NEVER GUESSES. Cancelling an alert about a player who has never been
-- near the arena is a real harm -- it is the silent hole the state bag's own
-- security note is written against, arrived at from the other direction. A
-- failure to suppress costs an operator an unwanted call-out; a wrong
-- suppression costs somebody a crime nobody was told about. So a firing this
-- cannot pin on an arena player is passed straight through, untouched, and
-- the name is printed once so the operator can fix the config.
--
-- WHY BOTH RegisterNetEvent AND AddEventHandler, which is not obvious and
-- was got wrong here once. FXServer delivers a network-sourced event only to
-- resources that have called RegisterNetEvent for that name, so a handler
-- registered with AddEventHandler alone never runs for the alerts that
-- matter -- gunfire and deaths are raised with TriggerServerEvent from the
-- player's own client, because that is where they are detected. The full
-- reasoning, including why this does not open anybody else's event to
-- clients, is at the RegisterNetEvent call itself further down.
-- ======================================================================

local function cancelConfig()
    local list = customConfig().cancelEvents
    return type(list) == 'table' and list or {}
end

local function readCancelEntry(key, entry)
    if Arena.IsKey(entry) then return { event = entry } end

    if type(entry) == 'table' and Arena.IsKey(entry.event) then
        local coordsIndex = Arena.ToInt(entry.coordsArg)
        if coordsIndex and coordsIndex < 1 then coordsIndex = nil end

        local index = Arena.ToInt(entry.playerArg)
        if index and index < 1 then index = nil end
        return { event = entry.event, playerArg = index, coordsArg = coordsIndex }
    end

    if entry == true and Arena.IsKey(key) then return { event = key } end

    return nil
end

--- The x and y of anything shaped like a coordinate, or nil.
---
--- THROUGH Arena.IsPoint, WHICH IS THE ONE PLACE THAT KNOWS THE LIST.
---
--- Written out here it read `table` or `vector3` and nothing else -- so a
--- vector4, which is what a dispatch resource hands over when it sends
--- coordinates WITH a heading, was refused. In this runtime a vector is
--- its own type, so `type()` on one answers 'vector4' and NEVER 'table'.
--- The whole point of this is to recognise that a shot was fired inside an
--- arena; refusing the payload means it is not recognised, and the alert the
--- arena exists to swallow goes out to the city police instead. Silent, and
--- only on the servers whose dispatch sends a heading. DO NOT write the
--- types out again.
--- @param point any
--- @return number|nil x
--- @return number|nil y
local function pointXY(point)
    if not Arena.IsPoint(point) then return nil end

    local px, py = tonumber(point.x), tonumber(point.y)
    if not px or not py then return nil end
    -- Z TOO, when the point has one. It was dropped here, one call after
    -- the explosion handler had it in hand, and that is how the arena became
    -- a circle on the map instead of the sphere every other check uses.
    return px, py, tonumber(point.z)
end

--- Whether ONE live match's arena covers this spot.
---
--- SPLIT OUT OF insideLiveArena ON PURPOSE, because the explosion guard has
--- to ask WHICH round a blast landed in and not merely whether it landed in
--- one. Two questions off one circle: a second copy of the radius maths is
--- how the keep-out fence and this file came to disagree about a grown
--- round in the first place.
--- @param matchId string
--- @param px number
--- @param py number
--- @return boolean
-- AN ARENA WITH NO FENCE IS STILL AN ARENA, and reading it as "nowhere" took
-- the explosion guard off it entirely.
--
-- `boundary.enabled = false` is a supported setting -- README calls it an open
-- arena -- and Arena.BoundaryOf answers nil for one. This returned false on
-- that nil, and BOTH branches of explosionEvent are gated on it: the first
-- never ran, so a launcher ignored friendly fire and killed teammates the
-- crossfire guard refuses to let a bullet touch; the second never ran either,
-- so an open arena could be shelled from outside by anybody. Bullets stayed
-- refused the whole time, which is the shape that makes it hard to notice --
-- the rule works right up until somebody picks up an RPG.
--
-- So a missing fence falls back to the arena's own spawn ring, which every
-- arena has and which is where its fighters actually are, with
-- Config.Match.maxKillDistance as a floor under the radius. That is not a new
-- number: Arena.KillCeilingFor already falls back to exactly it for an arena
-- with no boundary, and it is the same question -- how far apart two people
-- can be and still be in the same fight.
--
-- STILL FALSE WHEN THERE IS NOTHING TO MEASURE FROM. An arena with no
-- boundary AND no spawn ring gives no centre, and a guess would be worse than
-- the gap: refusing explosions in a circle round the wrong point cancels other
-- people's. DO NOT invent a centre here.
-- A SPHERE, NOT A CIRCLE, and the difference is a kilometre. The skydome is
-- a platform at z 1201 with a 110-metre boundary; measured on x and y alone
-- that boundary was a 110-metre circle drawn on the Grand Senora desert
-- floor 1.2 kilometres underneath it, and every explosion a bystander set
-- off inside that circle -- on the ground, in a live skydome round they
-- could not see -- was cancelled as if it had landed in the arena. The
-- fence the fighters are held by is a sphere, the server's own distance
-- checks are three-dimensional and name a point directly under the
-- skydome's floor as the case they exist for, and the explosion handler
-- had the z in hand and dropped it one call later. So when a point carries
-- a z it is tested against the sphere. A point without one -- nothing in
-- the resource sends one, but the fallback costs nothing -- keeps the old
-- circle rather than refusing outright. DO NOT go back to x/y for a point
-- that has a z.
local function matchCoversPoint(matchId, px, py, pz)
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId) or nil
    local arena = match and Arena.GetArenaByKey(match.arenaKey) or nil
    if not arena then return false end

    local factor = math.max(1.0, tonumber(match.sizeFactor) or 1.0)

    local cx, cy, cz, radius
    local boundary = Arena.BoundaryOf(arena)

    if boundary and boundary.center then
        cx, cy, cz = tonumber(boundary.center.x), tonumber(boundary.center.y), tonumber(boundary.center.z)
        radius = (tonumber(boundary.radius) or 0) * factor
    else
        local area = Arena.GetSpawnArea(match.arenaKey, factor)
        if not area then return false end

        cx, cy, cz = area.x, area.y, tonumber(area.z)
        radius = math.max(tonumber(area.radius) or 0,
            math.max(0.0, tonumber((Config.Match or {}).maxKillDistance) or 0.0))
    end

    if not cx or not cy or not radius or radius <= 0 then return false end

    local dx, dy = px - cx, py - cy
    local dz = (pz ~= nil and cz ~= nil) and (pz - cz) or 0.0
    return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

local function insideLiveArena(point)
    local px, py, pz = pointXY(point)
    if not px then return false end

    -- Which arenas currently have somebody in them. Read from the same
    -- `active` table the player pin uses, so the two layers can never
    -- disagree about whether a match is running.
    for _, matchId in pairs(active) do
        if matchCoversPoint(matchId, px, py, pz) then return true end
    end

    return false
end

local function pinnedByLocation(entry, ...)
    if not entry.coordsArg then return false end

    local payload = (select(entry.coordsArg, ...))

    -- THE SAME QUESTION AS insideLiveArena, SO IT MUST BE THE SAME ANSWER.
    --
    -- These two kept their own hand-written type lists and drifted: a payload
    -- that WAS the point rather than a table carrying one was rejected here,
    -- forty lines before the function that would have taken it. Both now ask
    -- Arena.IsPoint, which is the only thing that knows every shape a
    -- coordinate arrives in -- vector4 included, and a vector is its own type
    -- here, never a 'table'. DO NOT give either of them a private list again.
    if not Arena.IsPoint(payload) then return false end

    -- A BARE POINT HAS NO `coords`, and reading one off it must not be
    -- mistaken for a payload that carries one.
    if type(payload) ~= 'table' then return insideLiveArena(payload) end

    return insideLiveArena(payload.coords or payload)
end

--- Who an alert is about, and the answer has to survive a client saying so.
---
--- THE DEFECT. `playerArg` names an argument carrying a server id, and every
--- one of these events is registered for the network -- so the "server id"
--- was whatever the sender put in that slot, and the sender can be any
--- player on the box. A client naming SOMEBODY ELSE's id is the shape of
--- every server-id bug this project has already fixed, and here it reaches
--- both halves of the layer at once: the cancel flag is raised over a
--- stranger's alert, and Form 5 then asks the dispatch script to withdraw a
--- call filed under that stranger's id. The retract block's own promise --
--- "the server id in the middle is the arena player's own" -- was true of
--- the arithmetic and false of the input.
---
--- WHAT DECIDES IT. `source` is the server's answer, not the payload's, and
--- it is set for the whole of an event handler. When it names a player, that
--- player is who fired this event and a declared id that disagrees is a
--- claim about somebody else -- refused, which leaves the alert alone. When
--- it is 0 or absent the firing came from another RESOURCE on the server,
--- which is the case `playerArg` was written for and the one shape a client
--- CANNOT produce, so the declared id stands.
--- @return integer|nil src -- who the alert is about, or nil for "leave it alone"
--- @return integer|nil impostor -- the player who claimed somebody else's id
local function responsibleFor(entry, ...)
    local fromSource = Arena.ToInt(source)
    if fromSource and fromSource <= 0 then fromSource = nil end

    if entry.playerArg then
        local declared = Arena.ToInt((select(entry.playerArg, ...)))
        if not declared or declared <= 0 then return nil end
        if fromSource and declared ~= fromSource then return nil, fromSource end
        return declared
    end

    if entry.coordsArg then return nil end

    return fromSource
end

local warnedCancel = {}

local sawFiring = {}

local sawJobs = {}

local MAX_JOB_KINDS = 32
local sawJobCount = 0
local warnedJobFlood = false

local MAX_JOB_NAMES = 12
local MAX_JOB_TEXT = 200

local function warnUnpinnable(entry)
    if warnedCancel[entry.event] then return end
    warnedCancel[entry.event] = true

    if entry.coordsArg then
        ArenaLog('cancelEvents: "%s" fired but its location was not inside any arena with a live match, so it was left alone. That is the normal answer for an alert about somewhere else -- if it should have matched, check argument %d really carries the coordinates.',
            entry.event, entry.coordsArg)
        return
    end

    ArenaLog('cancelEvents: "%s" fired with no player behind it, so it was left alone. Say which argument carries the server id -- { event = \'%s\', playerArg = 1 } -- or, if the payload only says WHERE, which argument carries that -- { event = \'%s\', coordsArg = 1 } -- or drop it from the list.',
        entry.event, entry.event, entry.event)
end

local function jobsNamedIn(...)
    for index = 1, select('#', ...) do
        local argument = (select(index, ...))
        if type(argument) == 'table' then
            local jobs = argument.job_table or argument.jobs
            if type(jobs) == 'table' then
                local names = {}
                for _, job in ipairs(jobs) do
                    if type(job) == 'string' then
                        names[#names + 1] = job
                        if #names >= MAX_JOB_NAMES then break end
                    end
                end
                if #names > 0 then
                    local text = table.concat(names, ', ')
                    if #text > MAX_JOB_TEXT then
                        text = text:sub(1, MAX_JOB_TEXT) .. '...'
                    end
                    return text
                end
            end
        end
    end
    return nil
end

local function crossfireConfig()
    return (Config.Match or {}).crossfireGuard or {}
end

local function crossfireEnabled()
    return crossfireConfig().enabled ~= false
end

local MAX_HITS = 32

local function ownerOfNetId(netId, packet)
    local cached = netIdOwners[netId]
    if cached and netIdOf(cached) == netId then return cached end

    if packet then
        if packet.rebuilt then return netIdOwners[netId] end
        packet.rebuilt = true
    end

    netIdOwners = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        if src then
            local owned = netIdOf(src)
            if owned then netIdOwners[owned] = src end
        end
    end

    return netIdOwners[netId]
end

--- Whether these two may damage each other.
---
--- SYMMETRIC ON PURPOSE, and it answers both halves of the request in one
--- rule: an outsider cannot hurt a fighter, and a fighter cannot hurt an
--- outsider. Two people in DIFFERENT matches are as separate as a fighter
--- and a passer-by, which matters at an arena two rounds share.
---
--- Nobody in a round means this is not our business, and the answer is yes.
---
--- SELF-DAMAGE IS ALLOWED, and it now needs saying out loud. It used to
--- fall out of the crossfire rule -- a player's match compared against
--- itself is equal whether that is a match id or nil -- and an explicit
--- early return for it was written here first and taken back out, because
--- mutation testing showed it could not change the answer. The team check
--- below changed that: a fighter is on their own team, so `friendlyFire =
--- false` would refuse a player their own grenade and their own fall, and
--- make every fighter in a team mode immortal to the one thing the arena
--- does not control. The line earns its place now; crossfire_spec fails
--- without it.
--- @param attacker number
--- @param victim number
--- @return boolean ok
--- @return string|nil reason -- why not, for the log
--- @return string|nil kind -- 'crossfire' or 'team', which decides how much of the packet dies
local function mayDamage(attacker, victim)
    if attacker == victim then return true end

    local attackerMatch, victimMatch = active[attacker], active[victim]
    if attackerMatch == nil and victimMatch == nil then return true end
    if attackerMatch == nil or attackerMatch ~= victimMatch then
        return false, 'they are not in the same round', 'crossfire'
    end

    -- SAME ROUND. NOW THE TEAMS DECIDE, and this is where friendlyFire was
    -- doing nothing at all.
    --
    -- Arena.CanDamage existed, was tested, and had exactly one caller:
    -- server/match.lua's kill attribution, which decides whether a kill is
    -- CREDITED. Nothing ever stopped the bullet. So Config.Teams.friendlyFire
    -- = false meant "shooting your teammate does not score" rather than "you
    -- cannot shoot your teammate" -- and a player emptying a magazine into
    -- their own side, killing them, and seeing no score change is not what
    -- that setting says.
    --
    -- weaponDamageEvent is the only place the damage itself can be refused,
    -- and this handler is already here doing the same job across matches.
    --
    -- ArenaLobby is defined by a file loaded after this one; this runs inside
    -- an event handler long after load, which is the arrangement
    -- fxmanifest.lua's server_scripts note describes. Guarded anyway, because
    -- a missing lobby must not turn every shot into an error.
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(attackerMatch)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return true end

    -- A WATCHER IS NOT A FIGHTER, and this is the first case config.lua names
    -- as the reason this guard exists at all.
    --
    -- server/match.lua's syncMatchBuckets puts a spectator in the match's own
    -- routing bucket -- deliberately, because watching requires seeing -- and
    -- raises the SAME dispatch flag on them that a fighter carries, so
    -- `active` says they are in the round. The crossfire half above therefore
    -- passes for a fighter shooting a spectator, and it always has. The team
    -- half could not catch it either: a spectator is not on `match.players`,
    -- so Arena.CanDamage was handed a nil team, read it as "not the same
    -- side" and allowed the shot. Their body is invisible and collisionless
    -- while the camera runs, but it is not invincible, and the camera hands
    -- it back the moment it runs out of fighters to follow.
    --
    -- FAILS CLOSED, unlike the missing-lobby case above, and the difference is
    -- what is unknown. There, the roster had not answered and refusing would
    -- have frozen a live round into a stalemate. Here the roster answered and
    -- one of these two is not in it.
    local shooter, target = match.players[attacker], match.players[victim]
    if shooter == nil or target == nil then
        return false, 'one of them is watching rather than fighting', 'crossfire'
    end

    -- AND BEING OUT OF THE ROUND IS WATCHING, WHATEVER THE ROSTER SAYS.
    --
    -- An eliminated fighter KEEPS their row on purpose -- the results board
    -- ranks off it, and with spectateOnElimination on they stay in the
    -- match's routing bucket to watch. Both tests above therefore pass for
    -- them, and their shots at the people still fighting were never
    -- cancelled: a player who is out for the round could spend the rest of
    -- it deleting whoever was about to win.
    --
    -- Nothing was gained by it on the board -- resolveKiller refuses to
    -- credit a kill to somebody eliminated -- which is exactly what made it
    -- pure griefing, and free.
    --
    -- Their own client holds them invisible and collisionless while the
    -- camera runs; that is a hold their own client owns, and this is the
    -- half the server owns.
    if Arena.IsEliminated(shooter) then
        return false, 'the shooter is out of the round', 'crossfire'
    end

    if Arena.CanDamage(match.modeKey, shooter.team, target.team) then
        return true
    end
    return false, 'they are on the same team and friendly fire is off', 'team'
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    -- THE CROSSFIRE SWITCH CARRIES THE FRIENDLY-FIRE CHECK TOO, and that is
    -- deliberate rather than an oversight.
    --
    -- Both refusals happen here, because weaponDamageEvent is the only place
    -- a shot can be refused at all. Running this handler with the guard
    -- switched off would break the promise crossfire_spec holds us to --
    -- "switching the guard off restores the old behaviour exactly" -- and an
    -- operator who turned it off asked for this resource to stop touching
    -- other people's damage.
    --
    -- crossfireGuard.enabled ships true, so friendly fire is enforced out of
    -- the box. config.lua says so beside the switch.
    if not crossfireEnabled() then return end

    if next(active) == nil then return end

    local attacker = tonumber(sender)
    if not attacker then return end

    local hits = type(data) == 'table' and data.hitGlobalIds or nil
    if type(hits) ~= 'table' then return end

    if #hits > MAX_HITS then
        ArenaDebug('crossfire: refused a damage packet from %s naming %d entities.', tostring(attacker), #hits)
        CancelEvent()
        return
    end

    local allowed, refusal, crossfire = 0, nil, false

    local packet = {}

    for _, entry in ipairs(hits) do
        local netId = tonumber(entry)
        local victim = netId and ownerOfNetId(netId, packet) or nil
        if victim then
            local ok, reason, kind = mayDamage(attacker, victim)
            if ok then
                if victim ~= attacker then allowed = allowed + 1 end
            else
                refusal = refusal or { victim = victim, reason = reason }
                if kind ~= 'team' then crossfire = true end
            end
        end
    end

    if refusal == nil then return end

    if crossfire or allowed == 0 then
        ArenaDebug('crossfire: %s may not damage %s -- %s.',
            tostring(attacker), tostring(refusal.victim), refusal.reason or 'refused')
        CancelEvent()
    end
end)

-- ======================================================================
-- THE SECOND PLACE DAMAGE IS REFUSED, and mayDamage's own comment above
-- says weaponDamageEvent is the only one. It was wrong about this handler
-- and this handler enforced nothing.
--
-- THE DEFECT. Anybody in ANY match was exempted here, unconditionally: no
-- same-round test and no team test. So on a team round with friendlyFire
-- off a grenade killed the thrower's own side, a fighter in one match could
-- shell the round being fought next door, and a fighter who was already OUT
-- of the round -- still in `active`, because an eliminated fighter stays to
-- watch -- could delete whoever was about to win with a launcher while
-- their bullets were being refused three functions up. All thirteen heavy
-- weapons ship enabled, at the owner's own instruction, so it is reachable
-- with the shipped catalogue.
--
-- WHAT AN EXPLOSION CANNOT BE ASKED. The packet carries a PLACE and never a
-- victim list, so the per-victim answer weaponDamageEvent gets is not
-- available here: who is standing in the blast is read off the fighters'
-- own positions instead. BLAST_METRES is this file's own number and DO NOT
-- read it as the game's -- it is how close a team-mate has to be before the
-- arena treats them as caught.
--
-- AND IT BENDS FOR A LAWFUL VICTIM, exactly as the spread rule does.
-- CancelEvent kills the whole explosion, so refusing one that also caught an
-- enemy would make standing next to a team-mate a shield against every
-- launcher in the arena -- the same regression crossfire_spec already
-- refuses for shotguns.
-- ======================================================================

local BLAST_METRES = 10.0

--- Where a fighter is standing right now, or nil.
---
--- Guarded the way netIdOf is: a server-side read of a client-owned entity
--- can legitimately fail, and a player who left mid-blast must not take the
--- handler down with them.
--- @param src number
--- @return any|nil coords
local function positionOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotIt, coords = pcall(GetEntityCoords, ped)
    if not gotIt then return nil end
    return coords
end

--- Why this fighter may not set off this explosion, or nil for "they may".
--- @param exploder number
--- @param matchId string
--- @param px number
--- @param py number
--- @return string|nil reason
local function explosionRefusal(exploder, matchId, px, py, pz)
    -- FAILS OPEN ON A LOBBY THAT HAS NOT ANSWERED, deliberately, and for the
    -- reason mayDamage gives: the thrower is already known to be in the round
    -- this blast landed in, and freezing a live round over a roster that is
    -- not there costs more than one unrefused grenade. DO NOT turn this into
    -- a refusal.
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return nil end

    local thrower = match.players[exploder]
    if thrower == nil then return 'they are watching rather than fighting' end
    if Arena.IsEliminated(thrower) then return 'the thrower is out of the round' end

    local reach = BLAST_METRES * BLAST_METRES
    local caught, lawful = false, false

    -- MEASURED AS A SPHERE, NOT A CIRCLE ON THE MAP, and pointXY's own
    -- comment records this exact class of mistake being fixed one call away:
    -- "Z TOO, when the point has one. It was dropped here ... and that is how
    -- the arena became a circle on the map instead of the sphere every other
    -- check uses." The z was dropped again here, and both directions of the
    -- error are real on a map with rooftops and a skydome.
    --
    -- A TEAM-MATE THIRTY METRES STRAIGHT UP counted as caught, so a grenade
    -- thrown at street level was refused on their account although the blast
    -- could never reach them -- a refusal the file's own rule calls worse
    -- than a miss, because nothing tells the thrower why their launcher did
    -- nothing.
    --
    -- AND AN ENEMY THIRTY METRES STRAIGHT UP counted as lawful, which is the
    -- half that lets a team-mate be hurt: an enemy on a roof made every blast
    -- below them a legitimate one, and the team-mate standing in it went up
    -- with it.
    --
    -- FALLS BACK TO THE FLAT READING when either point has no z rather than
    -- refusing to measure: explosionEvent can arrive without a posZ, and a
    -- circle is a worse answer than a sphere but a much better one than none.

    -- `match.players` is keyed by SERVER ID, so this is pairs and not ipairs.
    for src, row in pairs(match.players) do
        if src ~= exploder and not Arena.IsEliminated(row) then
            local at = positionOf(src)
            if at then
                local x, y, z = pointXY(at)
                if x then
                    local dx, dy = x - px, y - py
                    local squared = dx * dx + dy * dy
                    if z and pz then
                        local dz = z - pz
                        squared = squared + dz * dz
                    end
                    if squared <= reach then
                        if Arena.CanDamage(match.modeKey, thrower.team, row.team) then
                            lawful = true
                        else
                            caught = true
                        end
                    end
                end
            end
        end
    end

    if caught and not lawful then
        return 'it would land on their own team and friendly fire is off'
    end
    return nil
end

AddEventHandler('explosionEvent', function(sender, data)
    if not crossfireEnabled() then return end
    if next(active) == nil then return end

    if type(data) ~= 'table' then return end
    local x, y, z = tonumber(data.posX), tonumber(data.posY), tonumber(data.posZ)
    if not x or not y then return end

    local exploder = tonumber(sender)
    local ownMatch = exploder and active[exploder] or nil

    -- THEIR OWN ROUND, AND NOT MERELY SOME ROUND. "Are they in a match" is
    -- what this asked, and DO NOT put that test back: it made a fighter at
    -- one arena free to shell the round being fought at another.
    if ownMatch and matchCoversPoint(ownMatch, x, y, z) then
        local refusal = explosionRefusal(exploder, ownMatch, x, y, z)
        if refusal then
            ArenaDebug('crossfire: refused an explosion from %s -- %s.', tostring(sender), refusal)
            CancelEvent()
        end
        return
    end

    if insideLiveArena({ x = x, y = y, z = z or 0.0 }) then
        ArenaDebug('crossfire: refused an explosion from %s inside a live arena.', tostring(sender))
        CancelEvent()
    end
end)

-- ======================================================================
-- WITHDRAWING AN ALERT THAT WAS ALREADY CREATED
-- (Config.Dispatch.custom.retract)
--
-- WHY THIS EXISTS AND CANCELEVENT DOES NOT REPLACE IT. CancelEvent() raises
-- a flag. Cfx's own documentation is explicit that it does not stop another
-- resource's handler from running, and a dispatch script that never calls
-- WasEventCanceled() -- which is most of them, sc-dispatch included -- will
-- create its call regardless. The layer above is therefore diagnostics on
-- this kind of script, not suppression. This is the layer that removes the
-- call.
--
-- HOW IT CAN KNOW THE ID. Dispatch scripts file a call under an id built
-- from facts that are not secret: sc-dispatch uses
-- '<kind>_<serverId>_<os.time()>', both of which this resource is holding at
-- the moment the same event reaches it. So the id is rebuilt rather than
-- read, and the operator states the shape in config rather than this file
-- assuming one.
--
-- WHY IT IS DELAYED. Both handlers hang off one event and nothing decides
-- which runs first. Clearing a call the other handler has not inserted yet
-- clears nothing, so the withdrawal is pushed past that handler's own work
-- with SetTimeout.
--
-- WHY IT CANNOT REACH SOMEBODY ELSE'S CALL. Every id it builds carries the
-- arena player's own server id in the middle. The clock slack widens the
-- timestamp, never the player.
-- ======================================================================

local function retractConfig()
    local block = customConfig().retract
    return type(block) == 'table' and block or {}
end

--- Every id shape listed for one entry, as a list.
---
--- ONE EVENT CAN FILE UNDER MORE THAN ONE SHAPE, and assuming otherwise is
--- what left a live server clearing its own calls by hand. The operator had
--- four shapes listed, the sweep dutifully asked for all four, and the call
--- sc-dispatch had actually filed was under a FIFTH -- 'emsdown_<id>_<time>'
--- -- which nothing here had ever been told about. Twenty-eight ids asked
--- for, not one of them the right one, and from the outside that is
--- indistinguishable from the withdrawal being broken.
---
--- So a shape may be a string or a list of them, and the list is what an
--- operator reaches for the moment their dispatch script files the same kind
--- of call under two names -- which this one does.
--- @param value string|string[]|nil
--- @return string[]
local function shapesOf(value)
    if Arena.IsKey(value) then return { value } end
    if type(value) ~= 'table' then return {} end

    local out = {}
    for _, shape in ipairs(value) do
        if Arena.IsKey(shape) then out[#out + 1] = shape end
    end
    return out
end

local function retractFor(entry, src)
    local config = retractConfig()
    if not Arena.IsKey(config.resource) or not Arena.IsKey(config.export) then return end

    local templates = config.idTemplates
    local shapes = shapesOf(type(templates) == 'table' and templates[entry.event] or nil)
    if #shapes == 0 then
        -- Not a warning. An event listed for cancelling with no id shape is
        -- an ordinary, deliberate state: Form 4 covers it and Form 5 does
        -- not claim to.
        return
    end

    if GetResourceState(config.resource) ~= 'started' then
        if not sawFiring['retract:' .. config.resource] then
            sawFiring['retract:' .. config.resource] = true
            ArenaLog('retract: Config.Dispatch.custom.retract names "%s", which is not started. Arena alerts will be raised and left standing.',
                config.resource)
        end
        return
    end

    local delay = Arena.ToInt(config.delayMs) or 250
    if delay < 0 then delay = 0 end

    local slack = Arena.ToInt(config.clockSlack) or 0
    if slack < 0 then slack = 0 end
    if slack > 5 then slack = 5 end

    local at = os.time()

    -- HOW MANY TIMES THE SAME WITHDRAWAL IS ASKED FOR, and why more than
    -- once.
    --
    -- THE REPORT: "its not even recalling the alert for a person down".
    -- This used to ask exactly once, `delayMs` after the event, and that
    -- number exists to land just after the other resource's handler. It does
    -- not reliably. sc-dispatch's AddNotification writes the call through
    -- oxmysql and AWAITS it, several statements deep, before a single EMS
    -- screen is told anything -- routinely longer than 250ms on a loaded
    -- server. A withdrawal that arrives first withdraws NOTHING: the UPDATE
    -- matches no row yet, and the clear reaches clients that have not been
    -- told about the call. Then the insert lands, the alert goes out, and it
    -- stays out. Indistinguishable, from the outside, from this layer never
    -- having run.
    --
    -- RETRIED RATHER THAN SWEPT. The uncertainty here is WHEN the call
    -- appears, not WHICH call it is: the id is already known from the event
    -- this handler is standing in. So the same small set of ids is asked for
    -- again on a widening delay, instead of rebuilding ids around a moving
    -- clock -- which would multiply the ids by every second it ran through
    -- and put three awaited UPDATEs behind each one, for a call that was
    -- already identified.
    --
    -- WIDENING, so a fast server pays almost nothing and a slow one is still
    -- covered several seconds out. Shared with the filed path at the top of
    -- this file, which had this exact fault until it was.

    local function ask()
        for _, template in ipairs(shapes) do
        for offset = -slack, slack do
            -- THE FORMAT IS OPERATOR TEXT AND IT WAS OUTSIDE THE pcall.
            --
            -- `idTemplates` is a string typed into config.lua. string.format
            -- RAISES on a shape it cannot fill -- a stray '%q', a '%d' handed
            -- something that is not a number, one specifier too many -- and
            -- this line sat above the guard that was catching the export
            -- call, inside a SetTimeout body with nothing above it to catch
            -- anything. One mistyped template therefore threw out of a timer
            -- rather than printing a line an operator could act on, and it
            -- did it on every arena alert for the rest of the run.
            --
            -- Built the way shared/compat/dispatch.lua's say() builds its
            -- own: pcall(string.format, ...) and DO NOT put the colon call
            -- back.
            local built, id = pcall(string.format, template, src, at + offset)
            if not built then
                if not sawFiring['retract:id:' .. entry.event] then
                    sawFiring['retract:id:' .. entry.event] = true
                    ArenaLog('retract: the id template for "%s" (%s) cannot be filled in (%s). It wants exactly two placeholders -- the player\'s server id and a unix timestamp, both numbers, as in \'shots_%%d_%%d\'. Nothing is being withdrawn for that event.',
                        entry.event, tostring(template), tostring(id))
                end
                return
            end

            local ok, err = pcall(function()
                exports[config.resource][config.export](nil, id)
            end)
            if not ok then
                if not sawFiring['retract:err:' .. config.resource] then
                    sawFiring['retract:err:' .. config.resource] = true
                    ArenaLog('retract: %s:%s failed (%s). Check that export name against that resource\'s own documentation.',
                        config.resource, config.export, tostring(err))
                end
                return false
            end
        end
        end
        return true
    end

    for _, extra in ipairs(RETRY_AT) do
        SetTimeout(delay + extra, ask)
    end

    local shown, sample = pcall(string.format, shapes[1], src, at)
    ArenaDebug('retract: asking %s to clear %d shape(s) like "%s" (+/-%ds) for %s, %d times out to %dms.',
        config.resource, #shapes, shown and sample or tostring(shapes[1]), slack, tostring(src),
        #RETRY_AT, delay + RETRY_AT[#RETRY_AT])
end

--- Withdraw every call this server's dispatch script could have filed for
--- one player, WITHOUT having seen the event that filed it.
---
--- THE LIMIT IN FORM 5 THAT THIS EXISTS TO REMOVE. retractFor is reached
--- from inside a cancelEvents handler and nowhere else, so it can only
--- withdraw a call whose event this resource was listening to. That is fine
--- until an alert is raised by a path nobody named -- and on a live server
--- it was. sc-dispatch carries THREE separate ways to file a person-down
--- call, and only two of them go through the events an operator would think
--- to list:
---
---   a 500ms loop polling the down metadata, which raises
---   sc-dispatch:server:PlayerDown -- listed, cancelled, withdrawn;
---
---   a SECOND loop, in the same file, that files `mydispatch:requestEMS`
---   when a downed player presses a key -- listed here too, and only fires
---   if they press it;
---
---   and its server side, which any other resource can trigger directly.
---
--- Being told about an event is a promise nobody made. An operator cannot
--- list what they have not read, and a script they update can grow a fourth
--- path overnight.
---
--- SO THIS ASKS BY ID INSTEAD OF BY EVENT. Every id shape in `idTemplates`
--- is `<something>_<server id>_<unix time>` -- read out of the script that
--- builds them -- so knowing WHO went down and WHEN is enough to name every
--- call that could have been filed about them, whoever filed it. The arena
--- knows both.
---
--- IT CANNOT REACH ANYBODY ELSE'S CALL. The server id in the middle of every
--- id is this player's own, and the only ids asked for are the shapes the
--- operator listed. A clear for an id that was never filed does nothing.
---
--- SWEPT RATHER THAN FIRED ONCE, because the alert does not exist yet when
--- the fighter goes down: the medical script has to notice, the dispatch
--- script has to poll, and on a loaded server that is a second or two. Each
--- id is asked for ONCE -- a set, not a loop -- so a four-second window over
--- four templates is a couple of dozen calls and never the same one twice.
---
--- THAT EXPLANATION BELONGS TO ArenaDispatch.RetractCallsFor, which is four
--- hundred lines below and reached from Revive. It is written here because
--- the function it describes could not be, and the note is repeated in one
--- line at its own definition. DO NOT read the next block as a continuation
--- of it: what follows is a different function with the opposite approach.

--- WITHDRAWING A CALL BY ITS REAL NAME, the moment it is filed.
---
--- WHAT THE SWEEP BELOW HAS TO DO WITHOUT. RetractCallsFor knows who went
--- down and roughly when, and from that it BUILDS ids -- every shape in
--- `idTemplates`, across a few seconds of clock, hoping one of them is the
--- name the dispatch script actually used. It works, and it is guesswork:
--- it cannot withdraw a call filed under a shape nobody listed, and every
--- shape it asks for that does not exist is a call into somebody else's
--- resource for nothing.
---
--- IT DOES NOT HAVE TO GUESS. sc-dispatch files every single alert through
--- one function, and the first thing that function does -- before it writes
--- a database row, before it sends anything to anybody -- is announce the
--- whole call on a plain server event:
---
---     exports('AddNotification', function(data)
---         ...
---         TriggerEvent('sc-dispatch:server:witnessForward', data)
---         local insertId = nil          -- the DB write comes AFTER this
---
--- -- sc-dispatch/server/main.lua. It is there so NPC witnesses can spawn
--- for crimes without every crime script having to know about witnesses,
--- and the payload it carries is the caller's own table: the id the call
--- will be filed under, the jobs it is going to, and the player it is
--- about. Any resource on the server may listen.
---
--- So this listens. No shapes, no clock slack, no window: the exact id and
--- the exact job list, taken from the call itself rather than rebuilt.
---
--- WHICH ROUTES IT ACTUALLY COVERS, because "all of them" is not true and
--- the difference matters. Every route into that function is announced, yes
--- -- but this handler can only act on an announcement that says WHO the
--- call is about, and in sc-dispatch only the person-down and EMS builders
--- fill that field in. The gunfire builder and the panic relay do not, so a
--- shots-fired call about a fighter is announced like every other and
--- declined here in silence.
---
--- That is the right answer rather than a gap to close: without a subject
--- there is nothing to check the call against, and withdrawing on the
--- strength of an id alone would take a stranger's call off the responders'
--- screens. Gunfire is handled a layer earlier anyway -- cancelled at the
--- event, where an arena knows the shooter is its own.
---
--- WHY IT STILL WAITS, AND WHY IT ASKS MORE THAN ONCE. The announcement
--- happens BEFORE the rows are written, so withdrawing on the spot would
--- clear a call that does not exist yet and the real one would survive.
--- `delayMs` is that pause and it is the same number the sweep uses -- and
--- like the sweep, one shot at it is not enough. The write is awaited
--- several statements deep and routinely outruns 250ms on a loaded server;
--- see RETRY_AT at the top of this file, which is the schedule both paths
--- use for exactly this reason. Knowing the id makes it certain WHICH call
--- to clear and says nothing about WHEN it exists.
---
--- WHAT IT IS NOT, AGAIN. This is withdrawal, not prevention. The call is
--- filed, so it reaches a screen; what this removes is a call that STAYS
--- there until somebody clears it by hand. The edge-clear further up this
--- file is the half that tries to stop it being filed at all, and neither
--- is a guarantee on its own.
--- @param data table -- the announced call
--- @return boolean withdrawn
function ArenaDispatch.WithdrawFiledCall(data)
    if type(data) ~= 'table' then return false end

    local config = retractConfig()
    if not Arena.IsKey(config.resource) or not Arena.IsKey(config.export) then return false end

    local id = data[config.filedIdField or 'unique_id']
    if not Arena.IsKey(id) then return false end

    -- WHO THE CALL IS ABOUT, and it has to be somebody this round has a
    -- claim on. This runs for EVERY alert filed anywhere on the server --
    -- a robbery downtown, a real medical call, somebody else's fight -- so
    -- the gate is the whole safety of it: withdraw the wrong one and a
    -- player having a genuine emergency is taken off the responders'
    -- screens by a PvP arena they have never been near.
    --
    -- AND IT IS A WEAKER GUARANTEE THAN THE SWEEP'S, which is worth saying
    -- plainly because the two look alike. The sweep cannot reach anybody
    -- else's call by construction -- the server id in the middle of every id
    -- it builds is the arena player's own. Here the id and the subject are
    -- two fields of the SAME payload and nothing ties them together: a
    -- payload naming a fighter as the subject and somebody else's call as
    -- the id would be withdrawn. What stands between that and a live server
    -- is the dispatch script's own event surface, not this gate -- so an
    -- operator whose dispatch script takes alert payloads straight from
    -- clients should leave `filedEvent` empty and let the sweep do it.
    local src = Arena.ToInt(data[config.filedSubjectField or 'caller_source'])
    if src == nil or src <= 0 then return false end

    local left = leftAt[src]
    if active[src] == nil and (left == nil or os.time() - left > FILED_GRACE_S) then
        return false
    end

    local known, state = pcall(GetResourceState, config.resource)
    if not known or state ~= 'started' then return false end

    local jobs = data[config.filedJobsField or 'job_table']
    if type(jobs) ~= 'table' then jobs = nil end

    local delay = Arena.ToInt(config.delayMs)
    if delay == nil then delay = 250 end
    if delay < 0 then delay = 0 end
    if delay > 5000 then delay = 5000 end

    -- ONE SCHEDULE PER CALL ID, however many times it is announced.
    --
    -- This handler runs on somebody else's event, and nothing in this
    -- resource decides how often that event fires. Every announcement used to
    -- cost one export call; asking four times would have made it four, and a
    -- resource that can be made to shout at another resource in multiples is
    -- worth not writing however unlikely the path. It is also simply right:
    -- the same call announced twice is one call, and the second schedule
    -- would ask for an id the first has already cleared.
    --
    -- Released when the last attempt has gone out, not before, so a genuine
    -- re-file of the same id later is still withdrawn.
    if withdrawing[id] then
        ArenaDebug('retract: "%s" is already being withdrawn -- not asked for again.', tostring(id))
        return true
    end
    withdrawing[id] = true

    ArenaLog('retract: withdrawing "%s" -- filed about %s, who is in a match.', tostring(id), tostring(src))

    local function ask()
        local ok, err = pcall(function()
            exports[config.resource][config.export](nil, id, jobs)
        end)
        if not ok and not sawFiring['filed:err:' .. config.resource] then
            sawFiring['filed:err:' .. config.resource] = true
            ArenaLog('retract: %s:%s failed on a filed call (%s).',
                config.resource, config.export, tostring(err))
        end
    end

    -- TIMERS RATHER THAN ONE THREAD THAT SLEEPS BETWEEN ASKS, which is how
    -- retractFor does it and the difference is not cosmetic: a thread that
    -- waits carries `id` and `jobs` for three seconds and, more to the
    -- point, one that throws takes the rest of the schedule with it. Each
    -- attempt here stands on its own.
    for index, extra in ipairs(RETRY_AT) do
        local last = index == #RETRY_AT
        SetTimeout(delay + extra, function()
            ask()
            if last then withdrawing[id] = nil end
        end)
    end

    return true
end

CreateThread(function()
    local name = retractConfig().filedEvent
    if not Arena.IsKey(name) then return end
    if type(AddEventHandler) ~= 'function' then return end

    AddEventHandler(name, function(data)
        ArenaDispatch.WithdrawFiledCall(data)
    end)
end)

--- Withdraws every call this server's dispatch script could have filed for
--- one player, by building the ids rather than being told them.
---
--- THE LONG RATIONALE IS ABOVE ArenaDispatch.WithdrawFiledCall, where it was
--- written and where it has to stay: it is the comparison between the two
--- approaches, and it reads as one argument. In short: this knows who went
--- down and roughly when, builds every shape in `idTemplates` across a few
--- seconds of clock, asks for each one once, and sweeps for `sweepMs`
--- because the alert does not exist yet when the fighter goes down.
--- @param src number
function ArenaDispatch.RetractCallsFor(src)
    if type(src) ~= 'number' or src <= 0 then return end

    -- ONLY FOR SOMEBODY THIS ROUND HAS A CLAIM ON. This sweep does not read
    -- an event -- it asks for ids blind -- so nothing else stops it clearing
    -- a REAL medical call. /arenarevive is the path that reaches it: an
    -- admin standing up an ordinary player who genuinely needs an ambulance
    -- would otherwise take that ambulance off the responders' screen.
    --
    -- RECENTLY-LEFT COUNTS, because the post-match sweep in server/match.lua
    -- runs seconds AFTER the flag comes down, and that sweep is the safety
    -- net this whole layer exists to be. A minute is far longer than the
    -- sweep and far shorter than a session.
    local left = leftAt[src]
    if active[src] == nil and (left == nil or os.time() - left > RETRACT_GRACE_S) then
        ArenaDebug('retract: %s is not in a match and did not just leave one -- withdrew nothing.',
            tostring(src))
        return
    end

    local config = retractConfig()
    if not Arena.IsKey(config.resource) or not Arena.IsKey(config.export) then return end

    local templates = config.idTemplates
    if type(templates) ~= 'table' or next(templates) == nil then return end

    local window = Arena.ToInt(config.sweepMs)
    if window == nil then window = 4000 end
    if window <= 0 then return end
    if window > 30000 then window = 30000 end

    -- ASKED THROUGH pcall, BECAUSE A NATIVE IS NOT A PROMISE. retractFor
    -- calls this bare and gets away with it: it is only ever reached from
    -- inside a cancelEvents handler, which needs a live event to fire. THIS
    -- one is reached from Revive, which every arena death goes through -- so
    -- it runs in places that native does not exist, and an unguarded call
    -- there takes the whole revive down with it. Measured: nine spec files
    -- went red on "attempt to call a nil value (global 'GetResourceState')".
    --
    -- UNREADABLE IS TREATED AS NOT RUNNING, which is the safe direction: the
    -- sweep does nothing and the alert is left standing, exactly as it would
    -- be on a server with no dispatch script at all.
    local known, state = pcall(GetResourceState, config.resource)
    if not known or state ~= 'started' then
        if known and not sawFiring['retract:' .. config.resource] then
            sawFiring['retract:' .. config.resource] = true
            ArenaLog('retract: Config.Dispatch.custom.retract names "%s", which is not started. Arena alerts will be raised and left standing.',
                config.resource)
        end
        return
    end

    local slack = Arena.ToInt(config.clockSlack) or 0
    if slack < 0 then slack = 0 end
    if slack > 5 then slack = 5 end

    CreateThread(function()
        local asked, cleared = {}, 0
        local deadline = GetGameTimer() + window

        repeat
            local now = os.time()

            for _, listed in pairs(templates) do
            for _, template in ipairs(shapesOf(listed)) do
                for offset = -slack, slack do
                    local built, id = pcall(string.format, template, src, now + offset)

                    if built and not asked[id] then
                        asked[id] = true
                        cleared = cleared + 1

                        local ok, err = pcall(function()
                            exports[config.resource][config.export](nil, id)
                        end)
                        if not ok then
                            if not sawFiring['retract:err:' .. config.resource] then
                                sawFiring['retract:err:' .. config.resource] = true
                                ArenaLog('retract: %s:%s failed (%s). Check that export name against that resource\'s own documentation.',
                                    config.resource, config.export, tostring(err))
                            end
                            return
                        end
                    end
                end
            end
            end

            Wait(500)
        until GetGameTimer() > deadline

        ArenaDebug('retract: swept %d call id(s) for %s over %dms -- every shape listed in '
            .. 'idTemplates, whether or not this resource saw the event that filed one.',
            cleared, tostring(src), window)
    end)
end

--- The tempo one player may fire one of these events at, in ms.
---
--- server/main.lua's loosest bucket on purpose, and for its stated reason:
--- "this only has to catch a flood, not pace anything." A dispatch alert is
--- at most as frequent as the death report that number was chosen for.
local CANCEL_RATE_MS = 200

--- Whether this firing is paced enough to do the work for.
---
--- THE DEFECT. Every one of these handlers is registered for the network,
--- because that is the only way FXServer delivers the client-triggered
--- alerts they exist for -- and not one of them had a limit of any kind.
--- Any player on the box could fire one in a loop: each firing walked the
--- payload for job names, walked the live arenas for the pin, and then
--- queued a timer whose body makes one call into another resource per second
--- of clock slack. A thousand firings bought a thousand timers and three
--- thousand of those calls, from a keybind.
---
--- THE HOUSE LIMITER, NOT A NEW ONE. ArenaRateLimit is what every
--- crimson_arena net event in server/main.lua already sits behind, keyed per
--- player and per bucket so one spammed event cannot starve another.
---
--- KEYED ON `source`, WHICH IS WHY IT IS SAFE. The limit is per PLAYER, so a
--- flooder can only throttle themselves; nobody can pace anybody else's
--- alerts by firing these. A firing with no player behind it -- another
--- resource raising the event on the server, which is the ordinary path -- is
--- never throttled at all.
---
--- WHAT A THROTTLED FIRING COSTS, said plainly rather than left implied: the
--- flag is not raised, so that one alert is not cancelled. This file's own
--- note on guessing says which way that error should fall -- "a failure to
--- suppress costs an operator an unwanted call-out; a wrong suppression costs
--- somebody a crime nobody was told about" -- and the player who pays is the
--- one doing the flooding.
--- @param eventName string
--- @return boolean
local function pacedEnough(eventName)
    local src = Arena.ToInt(source)
    if not src or src <= 0 then return true end

    -- server/util.lua is first in fxmanifest.lua's server_scripts, so this is
    -- always there in production; guarded because a file that loads without
    -- it must degrade rather than throw inside somebody else's event.
    if type(ArenaRateLimit) ~= 'function' then return true end

    return ArenaRateLimit(src, 'cancelEvents:' .. eventName, CANCEL_RATE_MS) == true
end

local warnedImpostor = {}

local function warnImpostor(entry, from)
    if warnedImpostor[entry.event] then return end
    warnedImpostor[entry.event] = true

    ArenaLog('cancelEvents: "%s" was fired by player %s naming a DIFFERENT server id, so it was left alone. A client CANNOT be taken at its word about who an alert is about -- acting on it would raise the cancel flag over a stranger\'s alert and ask your dispatch script to withdraw a call filed under their id. If your script really raises this from one player\'s client about another, drop playerArg from that entry and let `source` answer.',
        entry.event, tostring(from))
end

local function registerCancelHandler(entry)
    RegisterNetEvent(entry.event)

    AddEventHandler(entry.event, function(...)
        -- FIRST, AND BEFORE ANY OF THE BOOKKEEPING BELOW -- that is the
        -- expensive half and it reads a payload the caller chose, so DO NOT
        -- move this line down past it.
        if not pacedEnough(entry.event) then return end

        local jobs = jobsNamedIn(...)

        if not sawFiring[entry.event] then
            sawFiring[entry.event] = true
            ArenaLog('cancelEvents: "%s" reached this resource for the first time -- the hook is live. If alerts still get through from here it is a pinning problem, not a plumbing one.',
                entry.event)
        end

        if jobs and not sawJobs[jobs] then
            if sawJobCount < MAX_JOB_KINDS then
                sawJobs[jobs] = true
                sawJobCount = sawJobCount + 1
                ArenaLog('cancelEvents: an alert for [%s] came through "%s". Alerts for jobs never listed here are being raised somewhere this resource cannot see.',
                    jobs, entry.event)
            elseif not warnedJobFlood then
                warnedJobFlood = true
                ArenaLog('cancelEvents: more than %d different job lists have come through these events, so no more will be recorded. On a normal server there are a handful; this many means either an unusual dispatch script or a player raising the event by hand.',
                    MAX_JOB_KINDS)
            end
        end

        if pinnedByLocation(entry, ...) then
            CancelEvent()
            ArenaDebug('cancelEvents: cancelled "%s" -- it is about a spot inside a live arena.', entry.event)
            return
        end

        local src, impostor = responsibleFor(entry, ...)
        if not src then
            if impostor then warnImpostor(entry, impostor) else warnUnpinnable(entry) end
            return
        end

        if not ArenaDispatch.IsPlayerInArena(src) then
            ArenaDebug('cancelEvents: "%s" fired for %s, who is not in a match -- left alone, which is correct.',
                entry.event, tostring(src))
            return
        end

        CancelEvent()
        ArenaDebug('dispatch: raised the cancel flag on "%s" for %s, who is in match %s. It only stops the alert if that resource checks WasEventCanceled().',
            entry.event, tostring(src), tostring(active[src]))

        retractFor(entry, src)
    end)
end

-- Registration itself. Deliberately quiet: shared/compat/dispatch.lua's
-- startup report is the one place an operator is told how many of these are
-- live, and a second line saying the same thing at every boot is how a
-- console stops being read.
do
    local registered = {}
    for key, entry in pairs(cancelConfig()) do
        local normalised = readCancelEntry(key, entry)
        if not normalised then
            ArenaLog('cancelEvents: skipped an entry that is not an event name, { event = ... } or [event] = true.')
        elseif registered[normalised.event] then
            ArenaDebug('dispatch: cancelEvents names "%s" more than once -- the later entry was ignored.', normalised.event)
        else
            registered[normalised.event] = true
            registerCancelHandler(normalised)
        end
    end
end

--[[
    crimson_arena/tests/fixtures/world.lua

    A MODEL OF THE GAME, big enough to run the real client/match.lua against.

    WHY THIS EXISTS. The arena in the sky builds its own floor out of props
    and then stands people on it. Every part of that is natives -- load a
    model, measure it, create an object, put a ped on top -- and natives do
    not exist outside the game, so the whole feature was shipping on reading
    rather than on running. It shipped broken three separate ways.

    WHAT THIS IS NOT. It is not GTA. It is a model, and a model is only worth
    what its rules are worth, so the rules it enforces are written out here
    rather than buried:

      1. A MODEL THIS BUILD DOES NOT HAVE CANNOT BE LOADED. `models` is the
         object list of the server being simulated. A name outside it fails
         IsModelInCdimage exactly as an invented name does -- which is how
         the fallback chains get exercised rather than assumed.

      2. AN OBJECT IS ONLY CREATED WHERE THE WORLD IS STREAMED. CreateObject
         returns 0 beyond `streamRange` of the player. This is the rule that
         matters most and the one worth being honest about: the real engine
         is messier than a hard radius -- it will sometimes hand back a
         handle for scenery it has not really placed. Modelling it as a clean
         refusal is deliberately STRICTER than the game, because the
         behaviour the resource needs is the same either way: build the floor
         where the player is, not a kilometre away from them. Code that
         passes here does not depend on the engine being generous.

      3. A PROP HAS A REAL SHAPE. GetModelDimensions answers from the table,
         so tiling and surface height are computed from something rather than
         from zero, and a floor with a hole in it is a hole a test can stand
         a player in.

      4. GEOMETRY IS KEPT. Every object's model, position and heading is
         recorded, and deletes are recorded too, so "is there a floor under
         this player" and "did the arena tidy up after itself" are questions
         with real answers instead of call counts.

    The numbers in DEFAULT_MODELS are approximations of real GTA props --
    close enough that the arithmetic is exercised on plausible shapes. No
    test asserts a specific one of them, precisely because they are
    approximations: they are the input, never the expected answer.
]]

local World = {}

--- The object list of the build being simulated: footprint, and how far the
--- prop's top sits above its own origin.
--- @type table<string, table>
World.DEFAULT_MODELS = {
    -- The stunt/DLC building blocks the sky floor is tiled from. Big, square
    -- and solid, with the origin in the middle -- so `top` is half the
    -- height, which is exactly the case that breaks code assuming otherwise.
    stt_prop_stunt_bblock_huge_01 = { x = 40.0, y = 40.0, top = 10.0 },
    bkr_prop_biker_bblock_huge_01 = { x = 40.0, y = 40.0, top = 10.0 },
    imp_prop_impexp_bblock_huge_01 = { x = 40.0, y = 40.0, top = 10.0 },
    ar_prop_ar_bblock_huge_01 = { x = 40.0, y = 40.0, top = 10.0 },

    -- A shipping container: long, thin, origin on the floor of it. The prop
    -- that makes per-axis tiling matter.
    prop_container_01a = { x = 12.2, y = 2.5, top = 2.6 },
    prop_container_01b = { x = 12.2, y = 2.5, top = 2.6 },

    -- Cover.
    prop_conc_blocks01a = { x = 2.4, y = 1.2, top = 1.1 },
    prop_mp_barrier_02b = { x = 3.0, y = 0.4, top = 1.1 },
    prop_barrier_work05 = { x = 2.0, y = 0.5, top = 1.0 },
}

--- @param opts table? -- { models, streamRange, start }
--- @return table world
function World.new(opts)
    opts = opts or {}

    local w = {
        --- The object list of this simulated build.
        models = opts.models or World.DEFAULT_MODELS,
        --- How far from the player the engine is holding the world.
        streamRange = tonumber(opts.streamRange) or 350.0,
        --- Every object ever created, by handle. Deleted ones stay, flagged,
        --- so a spec can tell "never built" from "built and cleaned up".
        objects = {},
        --- Handles in creation order.
        order = {},
        --- Models that were asked for and refused for being out of range.
        refused = {},
        --- Which models were requested at all.
        requested = {},
        ped = 100,
        pedPos = opts.start or { x = -282.0, y = -2030.0, z = 30.1 },
        pedHeading = 0.0,
        frozen = false,
        timer = 0,
        nextHandle = 5000,
    }

    local function distance2(a, b)
        local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- Every object still standing.
    --- @return table[]
    function w.live()
        local out = {}
        for _, handle in ipairs(w.order) do
            local object = w.objects[handle]
            if object and not object.deleted then out[#out + 1] = object end
        end
        return out
    end

    --- Live objects of one model.
    --- @param model string
    function w.liveOf(model)
        local out = {}
        for _, object in ipairs(w.live()) do
            if object.model == model then out[#out + 1] = object end
        end
        return out
    end

    --- THE QUESTION THE WHOLE SKY ARENA TURNS ON: is there a solid surface
    --- directly under this point, and where is its top?
    ---
    --- Objects are treated as axis-aligned boxes, which is what a floor tile
    --- and a shipping container are close enough to. A prop rotated 45
    --- degrees would need more than this -- and nothing is placed onto cover,
    --- so nothing needs more than this.
    ---
    --- `only` narrows it to a set of model names, which is how a spec asks
    --- about the FLOOR rather than about whatever is standing on it. Without
    --- it, "is this barrier sitting on the floor" is answered by the barrier
    --- itself and every piece looks buried.
    --- @param x number
    --- @param y number
    --- @param only table<string, boolean>? -- models to consider, all if nil
    --- @return number|nil surfaceZ -- the highest top under the point
    --- @return table|nil object
    function w.surfaceUnder(x, y, only)
        local best, bestObject = nil, nil
        for _, object in ipairs(w.live()) do
            local size = w.models[object.model]
            if size and (only == nil or only[object.model]) then
                local halfX, halfY = size.x * 0.5, size.y * 0.5
                -- A heading of 90 or 270 swaps the footprint's axes.
                local turned = math.abs((object.heading or 0.0) % 180.0 - 90.0) < 45.0
                if turned then halfX, halfY = halfY, halfX end
                if math.abs(x - object.x) <= halfX and math.abs(y - object.y) <= halfY then
                    local top = object.z + (size.top or 0.0)
                    if not best or top > best then
                        best, bestObject = top, object
                    end
                end
            end
        end
        return best, bestObject
    end

    -- ==================================================================
    -- THE NATIVES
    -- ==================================================================

    w.natives = {
        joaat = function(name) return name end,

        IsModelInCdimage = function(name) return w.models[name] ~= nil end,
        IsModelValid = function(name) return w.models[name] ~= nil end,
        RequestModel = function(name) w.requested[name] = (w.requested[name] or 0) + 1 end,
        HasModelLoaded = function(name) return w.models[name] ~= nil end,
        SetModelAsNoLongerNeeded = function() end,

        GetModelDimensions = function(name)
            local size = w.models[name]
            if not size then return nil, nil end
            -- Origin in the middle horizontally, and `top` above it -- the
            -- shape the real native reports.
            return { x = -size.x * 0.5, y = -size.y * 0.5, z = (size.top or 0.0) - (size.height or size.top or 0.0) },
                   { x = size.x * 0.5, y = size.y * 0.5, z = size.top or 0.0 }
        end,

        CreateObject = function(name, x, y, z)
            -- RULE 2. Scenery is created into the streamed world, and the
            -- streamed world is the bubble around the player.
            if distance2({ x = x, y = y, z = z }, w.pedPos) > w.streamRange then
                w.refused[#w.refused + 1] = { model = name, x = x, y = y, z = z }
                return 0
            end
            w.nextHandle = w.nextHandle + 1
            local handle = w.nextHandle
            w.objects[handle] = {
                handle = handle, model = name,
                x = x, y = y, z = z, heading = 0.0,
                frozen = false, collision = false, deleted = false,
            }
            w.order[#w.order + 1] = handle
            return handle
        end,

        DeleteObject = function(handle)
            local object = w.objects[handle]
            if object then object.deleted = true end
        end,

        SetEntityAsMissionEntity = function() end,
        SetEntityCollision = function(handle, on)
            local object = w.objects[handle]
            if object then object.collision = on == true end
        end,
        SetEntityInvincible = function() end,

        DoesEntityExist = function(handle)
            local object = w.objects[handle]
            if object then return not object.deleted end
            -- Anything that is not one of our objects is a ped, and peds in
            -- this world always exist.
            return true
        end,

        FreezeEntityPosition = function(handle, on)
            local object = w.objects[handle]
            if object then
                object.frozen = on == true
            else
                w.frozen = on == true
            end
        end,

        SetEntityHeading = function(handle, heading)
            local object = w.objects[handle]
            if object then
                object.heading = heading
            else
                w.pedHeading = heading
            end
        end,

        SetEntityCoordsNoOffset = function(handle, x, y, z)
            local object = w.objects[handle]
            if object then
                object.x, object.y, object.z = x, y, z
            else
                w.pedPos = { x = x, y = y, z = z }
            end
        end,

        GetEntityCoords = function(handle)
            local object = w.objects[handle]
            if object then return { x = object.x, y = object.y, z = object.z } end
            if handle == w.ped then return { x = w.pedPos.x, y = w.pedPos.y, z = w.pedPos.z } end
            -- Any other ped: spread out by handle so "furthest from the
            -- nearest opponent" has a real answer rather than a tie.
            return { x = 1000.0 + (tonumber(handle) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,

        GetEntityHeading = function() return w.pedHeading end,
        PlayerPedId = function() return w.ped end,

        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        -- THE GROUND, and it is the real map: an honest downward search
        -- finds terrain at map height wherever it is asked from, which is
        -- exactly the answer that teleports a sky fighter out of the arena
        -- if anybody asks.
        GetGroundZFor_3dCoord = function(_x, _y, _z) return true, 30.0 end,

        GetGameTimer = function()
            w.timer = w.timer + 1
            return w.timer
        end,
    }

    return w
end

return World

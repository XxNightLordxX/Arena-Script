--[[
    tests/testkit.lua

    Zero-dependency assertion + test-runner for plain lua5.4. See
    DEVELOPER_REFERENCE.md for why this exists instead of busted (not installed
    for Lua 5.4 in this environment -- only for Lua 5.1 via luarocks).

    USAGE (see any *_spec.lua for a full example):
        local t = dofile('testkit.lua')
        t.test('description of one behavior', function()
            t.equals(1 + 1, 2)
        end)
        os.exit(t.summary())

    Every t.test() body runs inside its own pcall -- one failing assertion
    (t.equals/t.isTrue/... calling error()) fails only that one test, never
    aborts the rest of the file.
]]

local M = {}

M.passed = 0
M.failed = 0
M.failures = {}

--- Runs `fn` as one named test case. Never throws -- a failure inside `fn`
--- (an assertion error, or any other Lua error) is caught and recorded.
--- @param name string
--- @param fn fun()
function M.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        M.passed = M.passed + 1
        print(('  [PASS] %s'):format(name))
    else
        M.failed = M.failed + 1
        M.failures[#M.failures + 1] = { name = name, err = err }
        print(('  [FAIL] %s -- %s'):format(name, tostring(err)))
    end
end

--- @param actual any
--- @param expected any
--- @param message string?
function M.equals(actual, expected, message)
    if actual ~= expected then
        error(('%sexpected %s, got %s'):format(
            message and (message .. ': ') or '', tostring(expected), tostring(actual)
        ), 2)
    end
end

--- @param actual any
--- @param message string?
function M.isTrue(actual, message)
    M.equals(actual, true, message)
end

--- @param actual any
--- @param message string?
function M.isFalse(actual, message)
    M.equals(actual, false, message)
end

--- @param actual any
--- @param message string?
function M.isNil(actual, message)
    if actual ~= nil then
        error(('%sexpected nil, got %s'):format(
            message and (message .. ': ') or '', tostring(actual)
        ), 2)
    end
end

--- @param actual any
--- @param message string?
function M.isNotNil(actual, message)
    if actual == nil then
        error(('%sexpected a non-nil value'):format(message and (message .. ': ') or ''), 2)
    end
end

--- Substring containment check -- used throughout the admin.lua/progression.lua
--- specs to assert on captured print()/notify output without depending on
--- exact formatting.
--- @param haystack string
--- @param needle string
--- @param message string?
function M.contains(haystack, needle, message)
    haystack = tostring(haystack)
    if not haystack:find(needle, 1, true) then
        error(('%sexpected %q to contain %q'):format(
            message and (message .. ': ') or '', haystack, needle
        ), 2)
    end
end

--- @param haystack string
--- @param needle string
--- @param message string?
function M.notContains(haystack, needle, message)
    haystack = tostring(haystack)
    if haystack:find(needle, 1, true) then
        error(('%sexpected %q NOT to contain %q'):format(
            message and (message .. ': ') or '', haystack, needle
        ), 2)
    end
end

--- Prints the final pass/fail tally and returns a process exit code (0 if
--- everything passed, 1 otherwise) -- pass straight to os.exit().
--- @return integer exitCode
function M.summary()
    print('')
    print(('%d passed, %d failed'):format(M.passed, M.failed))
    if M.failed > 0 then
        print('')
        print('Failures:')
        for _, failure in ipairs(M.failures) do
            print(('  - %s: %s'):format(failure.name, tostring(failure.err)))
        end
    end
    return M.failed == 0 and 0 or 1
end

return M

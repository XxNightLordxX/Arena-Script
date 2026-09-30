# Harnesses

Each of these loads the resource's REAL `server/util.lua` and `server/ammo.lua`
(or `betting.lua`) under a fake FiveM environment and runs it with `lua5.4`.
They stub `exports`, `Config`, the `Arena*` globals and ox_inventory, and
nothing else — the logic under test is the shipped logic.

Run them from this directory:

    cd tools/harness
    for h in *.lua; do echo "--- $h"; lua5.4 "$h"; done

Or point them somewhere else:

    ARENA_ROOT=/path/to/Crimson-Arena/ lua5.4 dbtest.lua

## What each one proves

| File | Proves |
|---|---|
| `dbtest.lua` | With `Config.Database.enabled = false`, all eight public entry points run, nothing throws, and ZERO SQL statements are sent. |
| `ledger.lua` | The same debt is recorded with the database off and on, billed to the departed character; and a database user with SELECT but no INSERT reads as "not saved" rather than "saved". |
| `consumables.lua` | A logout mid-round records the debt; a stranger who inherits the server id loses nothing of their own; the door-off variant of the same. |
| `overbill.lua` | A player who fired their whole issue and owns the same items is billed nothing, because the count is taken before their own stash is handed back. |
| `stolen.lua` | A stolen weapon keeps its serial, stolen flag, owner, registration, components and tint through the full door cycle, and is not confiscated by an arena record that has no serial of its own. |
| `launder.lua` | An old consumable debt is not settled out of the arena's own freshly-issued loadout while the player is still in a round. |
| `betting.lua` | A second settle pays nothing extra; a pot is not paid to a character who took over the winner's server id. |

## How to use them

**Do not trust a passing run on its own.** Every one of these was written
alongside a CONTROL: revert the fix in the source, run again, and check the
number changes. Three times a harness "passed" only because the harness itself
was broken, and only the control revealed it.

Back the file up first, mutate the backup's copy, and restore from the backup
-- never `git checkout` to undo a mutation.

Known traps already hit and fixed in these files, worth remembering if you
write another:

- A fake `RemoveItem` must only decrement the PLAYER's pockets. `handBack`
  adds to the player and then removes from the stash, so a stub that
  decremented on both showed every returned item land and then vanish.
- `x and nil or y` always yields `y` in Lua. It silently disabled a
  read-only-database simulation.
- Stub every `Arena.*` helper the module actually calls. An
  `AllIssuedItems` returning `{}` quietly emptied a snapshot the code
  depended on and made a real fix look like a no-op.

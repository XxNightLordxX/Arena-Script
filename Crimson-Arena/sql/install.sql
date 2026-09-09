-- crimson_arena/sql/install.sql
--
-- YOU DO NOT NORMALLY NEED TO RUN THIS.
--
-- The resource creates this table itself on first start, from the identical
-- CREATE TABLE in server/stats.lua (ArenaStats.EnsureSchema). This file exists
-- for the two cases where that is not good enough:
--
--   1. Your database user cannot CREATE TABLE at runtime, which is a sensible
--      way to run a production server. Import this once as an admin, then let
--      the resource run with a user that only has SELECT/INSERT/UPDATE on it.
--   2. You want the table to exist before the first match, so an operator
--      looking at the schema does not see it appear out of nowhere.
--
-- The statements below are a byte-for-byte match for the ones in
-- server/stats.lua and server/ammo.lua. If you edit one, edit both, or first
-- start after an import will quietly do nothing (IF NOT EXISTS) and leave you
-- on the older shape.
--
-- WHAT HAPPENS IF YOU NEVER IMPORT IT AND NEVER GRANT CREATE: nothing breaks.
-- Config.Database.enabled = false, or a failed create, leaves the resource in
-- memory-only mode: matches, betting, payouts and the panel all work exactly
-- the same.
--
-- WHAT YOU LOSE IS TWO THINGS. The all-time leaderboard stops surviving a
-- restart. And the arena stops remembering what players still owe it -- see
-- the second table below, which matters more.

CREATE TABLE IF NOT EXISTS crimson_arena_stats (
    citizenid VARCHAR(64) NOT NULL,
    name VARCHAR(128) NOT NULL DEFAULT '',
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    kills INT NOT NULL DEFAULT 0,
    deaths INT NOT NULL DEFAULT 0,
    earnings BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid)
);

-- Optional. The leaderboard orders by wins then kills; on a server with tens of
-- thousands of rows that is a filesort every time somebody opens the panel.
-- Below a few thousand players it is not worth the write cost, which is why the
-- resource does not create it for you.
-- CREATE INDEX idx_crimson_arena_stats_board ON crimson_arena_stats (wins DESC, kills DESC);

-- ----------------------------------------------------------------------
-- WHAT PLAYERS STILL OWE THE ARENA.
--
-- There is one way out of a round the exit cannot cover: the player on that
-- server id is no longer the character the arena armed. A mid-round character
-- switch, or a disconnect whose kit ox_inventory has already saved into
-- somebody who is not here. Reaching into whoever holds the id now would take
-- THEIR guns, so the debt is written down against the character instead and
-- collected the next time they are seen.
--
-- WITHOUT THIS TABLE THAT SLATE LIVES IN MEMORY, and a restart writes off
-- every outstanding weapon and every round. On a server that restarts nightly
-- that is a way to keep an arena loadout: log out mid-round and wait.
--
-- Unlike the stashes, none of this can be rebuilt. A stash is a real
-- ox_inventory row the resource can find again by name; a weapon debt is
-- identified only by the serial recorded here.
--
-- `ledger_key` is the serial for a weapon and the item name for a stack. It
-- exists because MySQL cannot put a UNIQUE index on "the serial, or the name
-- when there is no serial", so the key is composed before it is written. It
-- is what stops one weapon being written down twice and lets a stack of
-- rounds accumulate instead.
-- ----------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS crimson_arena_owed_kit (
    citizenid VARCHAR(64) NOT NULL,
    ledger_key VARCHAR(191) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    name VARCHAR(191) NOT NULL,
    serial VARCHAR(128) NULL,
    amount INT NOT NULL DEFAULT 1,
    written_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, ledger_key)
);

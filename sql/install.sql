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
-- The statement below is a byte-for-byte match for the one in server/stats.lua.
-- If you edit one, edit both, or first start after an import will quietly do
-- nothing (IF NOT EXISTS) and leave you on the older shape.
--
-- WHAT HAPPENS IF YOU NEVER IMPORT IT AND NEVER GRANT CREATE: nothing breaks.
-- Config.Database.enabled = false, or a failed create, leaves the resource in
-- memory-only mode: matches, betting, payouts and the panel all work exactly
-- the same. The only thing you lose is the all-time leaderboard surviving a
-- restart. Nothing else in this resource reads the database.

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

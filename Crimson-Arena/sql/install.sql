-- crimson_arena/sql/install.sql
--
-- YOU DO NOT NORMALLY NEED TO RUN THIS.
--
-- The resource creates both of its tables itself on first start, from the
-- matching CREATE TABLE statements in server/stats.lua (ArenaStats.EnsureSchema)
-- and server/ammo.lua (ArenaAmmo.LoadOwedKit). This file exists for the two
-- cases where that is not good enough:
--
--   1. Your database user cannot CREATE TABLE at runtime, which is a sensible
--      way to run a production server. Import this once as an admin, then let
--      the resource run with a user that has SELECT, INSERT, UPDATE and
--      DELETE on both tables.
--
--      DELETE IS NOT OPTIONAL, AND IT IS NEW. crimson_arena_stats only ever
--      upserts and never deletes anything, so SELECT/INSERT/UPDATE was enough
--      when it was the only table. crimson_arena_owed_kit deletes a row the
--      moment the debt it records is settled -- that is how a weapon handed
--      back stops being chased. Without the grant the row survives the
--      collection, the next restart reads the settled debt back in, and the
--      player is chased for ever for something they already returned. The
--      resource cannot see that failure: the error is reported on oxmysql's
--      console, not this one.
--   2. You want the table to exist before the first match, so an operator
--      looking at the schema does not see it appear out of nowhere.
--
-- EACH STATEMENT BELOW AND ITS COPY IN THE LUA MUST BE THE SAME STATEMENT,
-- character for character. There are exactly two copies and they are at
-- server/stats.lua (SCHEMA_SQL) and server/ammo.lua (KIT_SCHEMA_SQL). Edit one
-- and you must edit the other, or first start after an import will quietly do
-- nothing (IF NOT EXISTS) and leave you on whichever shape got there first.
--
-- THE CHARSET CLAUSE IS PART OF THAT and is the half most likely to be
-- forgotten: a table created without one takes the DATABASE's default, so the
-- same resource on two servers ends up with two different tables, and only one
-- of them can store a player whose name has an accent in it.
--
-- WHAT HAPPENS IF YOU NEVER IMPORT IT AND NEVER GRANT CREATE: nothing breaks.
-- Config.Database.enabled = false, or a failed create, leaves the resource in
-- memory-only mode: matches, betting, payouts and the panel all work exactly
-- the same.
--
-- WHAT YOU LOSE IS TWO THINGS. The all-time leaderboard stops surviving a
-- restart. And the arena stops remembering what players still owe it -- see
-- the second table below, which matters more.

-- ----------------------------------------------------------------------
-- WHY EVERY TABLE HERE NAMES ITS OWN CHARSET.
--
-- Neither table used to say, so both took whatever the database default was.
-- On a server whose default is latin1 -- still the shipped default on plenty
-- of MySQL 5.7 installs, and what an older my.cnf leaves you with -- a player
-- name with an accent or an emoji in it is not merely mangled. It is REFUSED:
-- MySQL answers "Incorrect string value: '\xF0\x9F...'" and the row is never
-- written. On a utf8mb3 default the accents get through and the emoji do not,
-- because utf8mb3 stops at three bytes and every emoji is four.
--
-- THAT FAILURE IS INVISIBLE FROM INSIDE THE GAME. The write goes out through
-- oxmysql, is refused there, and the error is printed on oxmysql's console.
-- ArenaStats.Flush sees a nil answer, treats it as "the database is down",
-- and requeues the row -- so the same doomed row is retried every flush for
-- the rest of the run, and when 5000 of them have piled up the queue starts
-- dropping the oldest. One player with an emoji in their name is enough.
--
-- utf8mb4 is the only charset that holds everything a player can be called.
-- utf8mb4_unicode_ci sorts them the way a person would expect.
--
-- THE TWO KEY COLUMNS ARE utf8mb4_bin ON PURPOSE, and it is not a style
-- choice. They are machine identifiers, not prose, and they are the primary
-- key: under a _ci collation `char:abc` and `char:ABC` are THE SAME ROW, so
-- two different characters would silently share one set of statistics, and
-- two different weapon serials would silently share one debt -- which is the
-- exact collision the `w:` / `i:` prefix below exists to prevent. A binary
-- collation compares them byte for byte, which is how the Lua compares them.
--
-- ROW_FORMAT=DYNAMIC is what pays for that. utf8mb4 reserves four bytes per
-- character in an index, so the (citizenid, ledger_key) key below asks for
-- 64*4 + 191*4 = 1020 bytes. InnoDB's old COMPACT format allows 767 and would
-- refuse the CREATE outright; DYNAMIC allows 3072. It is the default on MySQL
-- 5.7+ and MariaDB 10.2+ and is named here so that it does not depend on the
-- default. If a server old enough to refuse it ever turns up, drop the clause
-- and shorten ledger_key to 100 -- not the charset. Only the second table
-- needs it: the stats table's key is one 64-character column, 256 bytes, and
-- fits COMPACT's 767 with room to spare.
--
-- THIS FILE ONLY AFFECTS A TABLE THAT DOES NOT EXIST YET. Both statements are
-- CREATE TABLE IF NOT EXISTS, so importing this over an install that already
-- has the tables changes NOTHING -- including the charset. To convert one that
-- already exists, stop the resource, back it up, and run these two by hand:
--
--     ALTER TABLE crimson_arena_stats
--         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
--     ALTER TABLE crimson_arena_stats
--         MODIFY citizenid VARCHAR(64) CHARACTER SET utf8mb4
--                COLLATE utf8mb4_bin NOT NULL;
--
--     ALTER TABLE crimson_arena_owed_kit ROW_FORMAT=DYNAMIC;
--     ALTER TABLE crimson_arena_owed_kit
--         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
--     ALTER TABLE crimson_arena_owed_kit
--         MODIFY citizenid VARCHAR(64) CHARACTER SET utf8mb4
--                COLLATE utf8mb4_bin NOT NULL,
--         MODIFY ledger_key VARCHAR(191) CHARACTER SET utf8mb4
--                COLLATE utf8mb4_bin NOT NULL;
--
-- They are not run for you because an ALTER on a table that is not there
-- aborts the import, and because the second pair rebuilds the primary key on
-- a table the arena may be actively collecting from.
-- ----------------------------------------------------------------------

-- EVERY WIDTH BELOW WAS CHECKED AGAINST WHAT THE LUA ACTUALLY WRITES.
--
--   citizenid  ArenaStats.Record cuts it to 64 -- 64 BYTES, because Lua's
--              string.sub counts bytes. 64 bytes is never more than 64
--              characters, so it always fits.
--   name       cut to 128 bytes the same way, into 128 characters. Also
--              always fits. IT IS THE CUT ITSELF THAT IS THE RISK, not the
--              width: a cut that lands in the middle of a multi-byte
--              character produces a half character, and MySQL refuses the
--              whole row for that just as it refuses an emoji into latin1.
--              The column cannot fix that; the cut has to be done in
--              characters. Nothing in this file can do it.
--   wins/losses/kills/deaths  one per match, accumulated. INT tops out at
--              2.1 billion matches.
--   earnings   accumulated money, so BIGINT and not INT: a busy arena passes
--              INT's 2.1 billion in a way a match count never will.

CREATE TABLE IF NOT EXISTS crimson_arena_stats (
    citizenid VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    name VARCHAR(128) NOT NULL DEFAULT '',
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    kills INT NOT NULL DEFAULT 0,
    deaths INT NOT NULL DEFAULT 0,
    earnings BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- `losses` IS WRITTEN EVERY ROUND AND IS NOT ON THE BOARD YET. That is a gap
-- and not a spare column: the leaderboard selects name, wins, kills, deaths
-- and earnings, so a player who wins two rounds out of forty reads exactly
-- like one who has won two out of two. DO NOT DROP IT to tidy the schema --
-- the write is what makes surfacing it possible later, and dropping it throws
-- away every defeat recorded since the arena opened, which cannot be
-- reconstructed from anything else here.
--
-- `updated_at` IS FOR YOU, NOT FOR THE GAME. Nothing selects it and nothing
-- is meant to. It is the only way to answer "who has played since March" or
-- to prune an install that has collected ten years of one-match visitors, and
-- the database fills it in for free. Same instruction: leave it alone.

-- Optional. The leaderboard orders by wins then kills; on a server with tens of
-- thousands of rows that is a filesort every time somebody opens the panel.
-- Below a few thousand players it is not worth the write cost, which is why the
-- resource does not create it for you.
-- CREATE INDEX idx_crimson_arena_stats_board ON crimson_arena_stats (wins DESC, kills DESC);

-- ----------------------------------------------------------------------
-- WHAT PLAYERS STILL OWE THE ARENA.
--
-- Two things end up here. The first is the way out of a round the exit
-- cannot cover: the player on that server id is no longer the character the
-- arena armed -- a mid-round character switch, or a disconnect whose kit
-- ox_inventory has already saved into somebody who is not here. Reaching into
-- whoever holds the id now would take THEIR guns, so the debt is written down
-- against the character instead and collected the next time they are seen.
--
-- The second is quieter: ox_inventory refusing a removal at an ordinary exit.
-- The arena asked for its rounds back, was told no, and would otherwise have
-- dropped the record a line later and forgotten they were ever issued.
--
-- WITHOUT THIS TABLE THAT SLATE LIVES IN MEMORY, and a restart writes off
-- every outstanding weapon and every round. On a server that restarts nightly
-- that is a way to keep an arena loadout: log out mid-round and wait.
--
-- Unlike the stashes, none of this can be rebuilt. A stash is a real
-- ox_inventory row the resource can find again by name; a weapon debt is
-- identified only by the serial recorded here, and a stack of rounds only by
-- the number.
--
-- `ledger_key` is `w:` and the serial for a weapon, `i:` and the item name
-- for a stack. The prefix is load-bearing: without it a serial that happened
-- to read like an item name would collide on the primary key and one debt
-- would silently overwrite the other. It is what stops one weapon being
-- written down twice and lets a stack of rounds accumulate instead.
--
-- THE WIDTHS, AGAIN AGAINST WHAT THE LUA WRITES. Nothing on this table is
-- cut to length before it is sent -- unlike the stats table, ammo.lua passes
-- citizenid, the item name and the serial through as they came:
--
--   citizenid   a framework character id, eight or so characters. 64 is
--               generous. IF ONE EVER ARRIVES LONGER THAN 64 the row is
--               refused with "Data too long", on oxmysql's console, and the
--               debt is silently forgiven -- which is a free arena loadout.
--   ledger_key  two characters plus an ox_inventory serial or item name,
--               both of which that resource keeps short. 191 is the largest
--               this can be without the key outgrowing DYNAMIC's 3072 bytes.
--   kind        never passed as a parameter: 'weapon' and 'item' are written
--               into the statements themselves. 16 is six to spare.
--   name        an ox_inventory item name. serial: an ox_inventory serial.
--   amount      rounds owed, bounded by the per-weapon ammo.max in
--               config.weapons.lua (500 at the highest) and by the ledger
--               caps in ammo.lua long before INT is in sight.
-- ----------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS crimson_arena_owed_kit (
    citizenid VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    ledger_key VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    kind VARCHAR(16) NOT NULL,
    name VARCHAR(128) NOT NULL,
    serial VARCHAR(128) NULL,
    amount INT NOT NULL DEFAULT 1,
    written_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, ledger_key)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

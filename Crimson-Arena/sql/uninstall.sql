-- crimson_arena/sql/uninstall.sql
--
-- THIS DESTROYS EVERY ARENA STATISTIC YOU HAVE EVER RECORDED, AND FORGIVES
-- EVERY DEBT THE ARENA IS STILL OWED. There is no undo and the resource keeps
-- no second copy.
--
-- The two tables are different in kind. crimson_arena_stats is history: wins,
-- losses, kills, deaths and lifetime earnings. crimson_arena_owed_kit is a
-- claim on the present -- every arena weapon and every round currently out
-- with a player who has not handed it back. Dropping the first loses a
-- record; dropping the second gives things away.
--
-- STOP THE RESOURCE FIRST. The slate also lives in memory while the arena is
-- running, so dropping the table under a live server does not clear the
-- debts. It just stops them being recorded, silently, until the next restart.
--
-- Take a backup first. Genuinely:
--
--     mysqldump -u USER -p DATABASE crimson_arena_stats crimson_arena_owed_kit > crimson_arena.sql
--
-- Removing the resource does NOT require running this. An unused table costs
-- you nothing, and leaving it means reinstalling later keeps every record.
-- Run this only when you have decided the history itself is unwanted.
--
-- IF YOU CAME HERE TO FIX THE CHARSET, YOU ARE IN THE WRONG FILE. Both tables
-- name utf8mb4 in install.sql, but CREATE TABLE IF NOT EXISTS cannot change a
-- table that already exists, so the obvious repair -- drop them and let the
-- resource make them again -- is this file, and it takes the history and the
-- debts with it. sql/install.sql carries the ALTER TABLE statements that
-- convert a live table in place instead. Use those.
--
-- These two statements do not care what charset, collation or row format the
-- tables were created with; DROP removes the table whatever shape it is in.

DROP TABLE IF EXISTS crimson_arena_stats;

-- AND THE SLATE. This one is not history, it is a debt: dropping it forgives
-- every arena weapon and every round that players walked off with and have
-- not yet handed back. That is usually what you want when removing the
-- resource, and never what you want while it is still running.
DROP TABLE IF EXISTS crimson_arena_owed_kit;

-- The list of stashes the door was holding off. Dropping this does NOT empty
-- those stashes -- it only forgets that they were being held back, so a
-- resource still running would walk them again and hand out whatever is
-- parked in them. Settle them with /arenaunjam first if this server is
-- staying up.
DROP TABLE IF EXISTS crimson_arena_jammed_stash;

-- Money the arena still owed somebody. Dropping this FORGIVES those debts:
-- nobody is paid what was outstanding. Settle them first if that matters.
DROP TABLE IF EXISTS crimson_arena_unpaid;

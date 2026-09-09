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

DROP TABLE IF EXISTS crimson_arena_stats;

-- AND THE SLATE. This one is not history, it is a debt: dropping it forgives
-- every arena weapon and every round that players walked off with and have
-- not yet handed back. That is usually what you want when removing the
-- resource, and never what you want while it is still running.
DROP TABLE IF EXISTS crimson_arena_owed_kit;

-- crimson_arena/sql/uninstall.sql
--
-- THIS DESTROYS EVERY ARENA STATISTIC YOU HAVE EVER RECORDED. There is no undo
-- and the resource keeps no second copy: wins, losses, kills, deaths and
-- lifetime earnings for every player are in this one table.
--
-- Take a backup first. Genuinely:
--
--     mysqldump -u USER -p DATABASE crimson_arena_stats > crimson_arena_stats.sql
--
-- Removing the resource does NOT require running this. An unused table costs
-- you nothing, and leaving it means reinstalling later keeps every record.
-- Run this only when you have decided the history itself is unwanted.

DROP TABLE IF EXISTS crimson_arena_stats;

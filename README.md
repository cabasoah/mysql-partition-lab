# MySQL partitioning lab (CS3543 term paper) — version 2

A scaled-down GlobalCard `transaction` table in MySQL 8.4, built two ways so you can compare them:

| Table | Layout |
|---|---|
| `transaction_plain` | One monolithic InnoDB table (course DDL, PK `transaction_id`) plus an index on `transaction_date` so the monthly DELETE doesn't have to scan the whole table |
| `transaction_part` | `RANGE (UNIX_TIMESTAMP(transaction_date))` by month (84 months + `p_future`), `SUBPARTITION BY HASH (account_id)` × 16 (configurable) |

Both get identical synthetic data: 84 months (Nov 2019 to Oct 2026) spread over 100,000 accounts.

## What changed from version 1
- The DELETE is now fair (it uses a date index), and DELETE/DROP are each run three times with medians.
- `problemA` also measures: DELETE + ROLLBACK, rebuilding the table to get space back, three EXCHANGE
  round trips, three empty `p_future` splits and one split after rows have already landed in `p_future`.
- `problemB` adds the two-step cardholder search (`account_id IN (...)`), shows how the plain table is read
  and how many pages came from disk, and works out the 99.9% question for the current number of buckets.
- New steps: `locks`, `merchant`, `tiering`.
- Disk sizes are reported both as file size and as blocks actually allocated.
- The number of hash buckets per month can be changed (`SUBPARTS`, up to 96).
- Result files are named `<step>_<rows>x<buckets>.txt`, so runs don't overwrite each other.

## Run it

Open a terminal in this folder. **Git Bash on Windows:** run `export MSYS_NO_PATHCONV=1` first
(or use PowerShell).

```bash
# 0. Recreate the container with the new settings (your old data is rebuilt by setup anyway)
docker compose up -d
docker compose ps                  # wait until STATUS shows "healthy"
export MSYS_NO_PATHCONV=1

# 1. Main run at three sizes. For EACH size run these in this order:
docker compose exec mysql bash /tests/bench.sh setup 20000
docker compose exec mysql bash /tests/bench.sh problemB
docker compose exec mysql bash /tests/bench.sh problemA
docker compose exec mysql bash /tests/bench.sh locks
#    ...then repeat the four commands with  setup 50000  and  setup 100000

# 2. Once, at any size (after problemA is fine):
docker compose exec mysql bash /tests/bench.sh errors
docker compose exec mysql bash /tests/bench.sh merchant
docker compose exec mysql bash /tests/bench.sh tiering

# 3. Does DROP PARTITION's cost depend on the number of partitions? Same rows, different bucket counts:
docker compose exec -e SUBPARTS=4  mysql bash /tests/bench.sh setup 20000
docker compose exec mysql bash /tests/bench.sh problemA
docker compose exec -e SUBPARTS=96 mysql bash /tests/bench.sh setup 20000
docker compose exec mysql bash /tests/bench.sh problemB
docker compose exec mysql bash /tests/bench.sh problemA
```

`problemA` removes three months and `locks` removes two more, so always run `setup` before repeating them.
Every step saves its output in the `results` folder next to this README.

Rough times on a laptop: `setup 20000` about 2 minutes, `setup 50000` about 5, `setup 100000` about 10
(needs about 20 GB of free disk). `setup` with `SUBPARTS=96` creates 8,160 files, so keep it at 20000 rows.

## What each step measures
- **setup**: row counts, number of `.ibd` files, file size vs blocks allocated, smallest/largest partition file.
- **errors**: what MySQL refuses when you partition the course DDL as written (primary key without the
  partition column, foreign keys, `RANGE COLUMNS` on a `TIMESTAMP`, hashing on `cardholder_id`,
  Range-List composite), and a demonstration that `transaction_id` alone is no longer unique.
- **problemB**: for eight support-style searches, how many leaf partitions MySQL reads (from `EXPLAIN`),
  best-of-3 time on both tables, how the plain table is accessed, pages read from disk, and the
  number of buckets that a 99.9% skip would need.
- **problemA**: time, redo bytes (`Innodb_os_log_written`) and binary log bytes for DELETE vs
  DROP PARTITION on three successive months; rollback cost; disk before/after; `OPTIMIZE TABLE` to reclaim
  space; `EXCHANGE PARTITION` with and without validation; `REORGANIZE PARTITION p_future` empty and with rows.
- **locks**: a second session keeps running a SELECT and an INSERT while (1) a DELETE runs, (2) a DROP
  PARTITION waits behind an open transaction, (3) a DROP PARTITION runs unobstructed.
- **merchant**: two layouts for `tx_purchase` (month partitions + index, or month + `HASH(merchant_id)`),
  with one very large merchant to show hash skew, and the join back to `transaction`.
- **tiering**: a partition created on a second directory (`/cold`), moving existing partitions there
  with `REORGANIZE PARTITION ... DATA DIRECTORY` at two sizes, and compressing an archived month.

## Machine details for the paper
Record these once so the test environment can be described:
```bash
docker compose exec mysql bash -c "nproc; grep MemTotal /proc/meminfo; mysql -uroot -prootpass -e 'SELECT VERSION(), @@innodb_buffer_pool_size, @@innodb_page_size, @@transaction_isolation, @@binlog_format'"
```
Also note your laptop model, CPU, RAM, disk type and Docker Desktop version.

## Connecting with a GUI (optional)
MySQL Workbench / DBeaver: host `localhost`, port `3307`, user `root`, password `rootpass`, database `globalcard`.

## Start over / clean up
```bash
docker compose down -v      # stops MySQL and deletes all data
```

## Notes
- Don't open `tests/bench.sh` in Notepad and save it: Windows line endings break bash.
  If you see `$'\r': command not found`, run: `docker compose exec mysql sed -i 's/\r$//' /tests/bench.sh`
- If the container fails to start after the update, run `docker compose logs mysql` and send me the output.
- Timings depend on your machine. Compare the two tables on the **same** run, and use the growth across
  sizes, not the absolute numbers, when you extrapolate.

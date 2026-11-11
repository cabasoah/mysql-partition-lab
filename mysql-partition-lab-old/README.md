# MySQL partitioning lab (CS3543 term paper)

A scaled-down GlobalCard `transaction` table in MySQL 8.4, built two ways so you can compare them:

| Table | Layout |
|---|---|
| `transaction_plain` | One monolithic InnoDB table (course DDL, PK `transaction_id`) |
| `transaction_part` | `RANGE (UNIX_TIMESTAMP(transaction_date))` by month (84 months + `p_future`), `SUBPARTITION BY HASH (account_id)` × 16 |

Both tables get identical synthetic data: 84 months (Nov 2019 to Oct 2026), spread over 100,000 accounts. A small `card` table maps cardholders to accounts for the cardholder search.

## Requirements
- Docker Desktop (Windows/Mac) or Docker Engine (Linux)
- Free disk: about 2 GB for the small run, about 20 GB for the 100,000-rows-per-month run

## Run it

Open a terminal in this folder (PowerShell works on Windows).

```bash
# 1. Start MySQL (first start takes ~30 s)
docker compose up -d
docker compose ps                  # wait until STATUS shows "healthy"
export MSYS_NO_PATHCONV=1

# 2. Build and load the tables (rows per month; 20000 = 1.68M rows per table, a few minutes)
docker compose exec mysql bash /tests/bench.sh setup 20000

# 3. Capture the MySQL rules that shape the design (these are EXPECTED errors)
docker compose exec mysql bash /tests/bench.sh errors

# 4. Problem B: partitions scanned per support query, partitioned vs plain
docker compose exec mysql bash /tests/bench.sh problemB

# 5. Problem A: DELETE vs DROP PARTITION, EXCHANGE PARTITION, adding next month
docker compose exec mysql bash /tests/bench.sh problemA
```

Then repeat steps 2, 4 and 5 at a larger size (for example `setup 100000`) so you can show how
each operation **grows** with data volume. That growth is the evidence for extrapolating to 300 billion rows.

Every step saves its output in the `results` folder next to this README.

## What each step measures
- **setup**: row counts, number of `.ibd` files per table, disk size, sample partition file names.
- **errors**: what MySQL refuses when you partition the course DDL (PK without the partition column,
  foreign keys, `RANGE COLUMNS` on a `TIMESTAMP`, hashing on `cardholder_id`).
- **problemB**: for seven support-style queries, how many of the leaf partitions MySQL reads
  (from `EXPLAIN`'s `partitions` column) and the best-of-3 run time on both tables.
- **problemA**: time, redo log bytes (`Innodb_os_log_written`) and binary log bytes for
  `DELETE` of the oldest month vs `DROP PARTITION`; disk size before/after; `EXCHANGE PARTITION`
  on a subpartitioned table (with and without validation); `REORGANIZE PARTITION p_future`.

## Connecting with a GUI (optional)
MySQL Workbench / DBeaver: host `localhost`, port `3307`, user `root`, password `rootpass`, database `globalcard`.

## Start over / clean up
```bash
docker compose down -v      # stops MySQL and deletes all data
```

## Notes
- Don't open `tests/bench.sh` in Notepad and save it: Windows line endings break bash.
  If you see `$'\r': command not found`, run: `docker compose exec mysql sed -i 's/\r$//' /tests/bench.sh`
- `problemA` permanently drops the oldest month. Run `setup` again before repeating it.
- Timings depend on your machine. Compare the two tables on the **same** run, and use the growth between
  two sizes, not the absolute numbers, when you extrapolate.

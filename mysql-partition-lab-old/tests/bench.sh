#!/bin/bash
# =====================================================================
# GlobalCard partitioning lab for MySQL (CS3543 term paper)
#
# Run inside the container:
#   docker compose exec mysql bash /tests/bench.sh setup 50000
#   docker compose exec mysql bash /tests/bench.sh errors
#   docker compose exec mysql bash /tests/bench.sh problemB
#   docker compose exec mysql bash /tests/bench.sh problemA
#
# Results are written to /results (the ./results folder on your computer).
# =====================================================================
set -uo pipefail
shopt -s nullglob

DB=${DB:-globalcard}
DATADIR=${DATADIR:-/var/lib/mysql}
OUT=${OUT:-/results}
ACCOUNTS=${ACCOUNTS:-100000}      # number of accounts the rows are spread over
START=${START:-2019-11-01}        # oldest retained month (84 months -> Oct 2026)
MONTHS=84
SUBPARTS=16
export MYSQL_PWD="${MYSQL_PWD:-${MYSQL_ROOT_PASSWORD:-rootpass}}"
MYSQL=${MYSQL:-"mysql -uroot"}

mkdir -p "$OUT"
q()      { $MYSQL -N -B "$DB" -e "$1"; }            # run SQL, tab-separated output
qerr()   { $MYSQL -N -B "$DB" -e "$1" 2>&1; }        # run SQL, keep error text
now_ms() { date +%s%3N; }
status() { q "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='$1'"; }
binlog_bytes() { $MYSQL -N -B -e "SHOW BINARY LOGS" | { local s=0 n sz r; while IFS=$'\t' read -r n sz r; do s=$((s+sz)); done; echo $s; }; }
files_bytes()  { du -cb "$DATADIR/$DB"/$1 2>/dev/null | tail -1 | cut -f1; }
files_count()  { local f=( "$DATADIR/$DB"/$1 ); echo ${#f[@]}; }
mb()     { local b=$1; printf "%d.%02d MB" $((b/1048576)) $(( (b%1048576)*100/1048576 )); }
pct()    { local x=$(( $1*10000/$2 )); printf "%d.%02d%%" $((x/100)) $((x%100)); }
month()  { date -u -d "$START +$1 month" "$2"; }

# ---------------------------------------------------------------------
# setup ROWS_PER_MONTH : build both tables and load identical data
# ---------------------------------------------------------------------
setup() {
  local rows=${1:-50000}
  local log="$OUT/setup_${rows}.txt"
  echo "Building tables with $rows rows per month x $MONTHS months ($((rows*MONTHS)) rows per table)..."

  # 84 monthly range partitions on UNIX_TIMESTAMP(transaction_date), plus p_future
  local parts="" i name next
  for ((i=0; i<MONTHS; i++)); do
    name=$(month $i +p%Y_%m); next=$(month $((i+1)) +%Y-%m-01)
    parts+="PARTITION $name VALUES LESS THAN (UNIX_TIMESTAMP('$next 00:00:00')),"
  done
  parts+="PARTITION p_future VALUES LESS THAN MAXVALUE"

  q "DROP TABLE IF EXISTS transaction_part, transaction_plain, archive_tx, card, seq;"

  # helper: numbers 0..999
  q "CREATE TABLE seq (n INT PRIMARY KEY);
     INSERT INTO seq WITH RECURSIVE r(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM r WHERE n<999) SELECT n FROM r;"

  # (1) monolithic table: the course DDL, minus the FK to account (no account table is loaded)
  q "CREATE TABLE transaction_plain (
       transaction_id BIGINT NOT NULL, account_id BIGINT NOT NULL,
       transaction_type VARCHAR(20) NOT NULL, amount DECIMAL(15,2) NOT NULL,
       transaction_date TIMESTAMP NOT NULL, posted_date TIMESTAMP NOT NULL,
       description VARCHAR(255) NOT NULL, is_disputed BOOLEAN NOT NULL DEFAULT FALSE,
       CONSTRAINT CHK_plain_type CHECK (transaction_type IN ('PURCHASE','CASH_ADVANCE','FEE','INTEREST_CHARGE','PAYMENT','REFUND','ADJUSTMENT')),
       PRIMARY KEY (transaction_id),
       UNIQUE KEY uq_identity (transaction_id, transaction_type, account_id),
       KEY ix_account_posted (account_id, posted_date),
       KEY ix_account_txdate (account_id, transaction_date)
     ) ENGINE=InnoDB;"

  # (2) partitioned table: RANGE by month, HASH(account_id) x 16 inside each month.
  #     Every unique key must contain transaction_date and account_id (partitioning columns).
  q "CREATE TABLE transaction_part (
       transaction_id BIGINT NOT NULL, account_id BIGINT NOT NULL,
       transaction_type VARCHAR(20) NOT NULL, amount DECIMAL(15,2) NOT NULL,
       transaction_date TIMESTAMP NOT NULL, posted_date TIMESTAMP NOT NULL,
       description VARCHAR(255) NOT NULL, is_disputed BOOLEAN NOT NULL DEFAULT FALSE,
       CONSTRAINT CHK_part_type CHECK (transaction_type IN ('PURCHASE','CASH_ADVANCE','FEE','INTEREST_CHARGE','PAYMENT','REFUND','ADJUSTMENT')),
       PRIMARY KEY (transaction_id, transaction_date, account_id),
       UNIQUE KEY uq_identity (transaction_id, transaction_type, account_id, transaction_date),
       KEY ix_account_posted (account_id, posted_date),
       KEY ix_account_txdate (account_id, transaction_date)
     ) ENGINE=InnoDB
     PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date))
     SUBPARTITION BY HASH (account_id) SUBPARTITIONS $SUBPARTS
     ($parts);"

  # card table so a cardholder search can be routed to account_id (cardholder_id is not on transaction)
  q "CREATE TABLE card (card_id BIGINT PRIMARY KEY, account_id BIGINT NOT NULL, cardholder_id BIGINT NOT NULL,
       KEY ix_card_cardholder (cardholder_id), KEY ix_card_account (account_id)) ENGINE=InnoDB;
     INSERT INTO card SELECT a.n*1000+b.n+1, 1+((a.n*1000+b.n) % $ACCOUNTS), 1+((a.n*1000+b.n) % 120000)
       FROM seq a CROSS JOIN seq b WHERE a.n < 150;"

  # load month by month (binary logging off for the load so later measurements stay clean)
  local t0=$(now_ms) mstart mnext
  for ((i=0; i<MONTHS; i++)); do
    mstart=$(month $i +%Y-%m-01); mnext=$(month $((i+1)) +%Y-%m-01)
    q "SET sql_log_bin=0;
       INSERT INTO transaction_plain
       SELECT id, acct, typ, amt, td, td + INTERVAL FLOOR(RAND()*3) DAY, 'synthetic transaction', RAND() < 0.0005
       FROM (SELECT $((i*10000000)) + a.n*1000 + b.n + 1 AS id,
                    1 + FLOOR(RAND()*$ACCOUNTS) AS acct,
                    ELT(1+FLOOR(RAND()*10),'PURCHASE','PURCHASE','PURCHASE','PURCHASE','PAYMENT','REFUND','FEE','INTEREST_CHARGE','CASH_ADVANCE','ADJUSTMENT') AS typ,
                    ROUND(RAND()*500,2) AS amt,
                    TIMESTAMP('$mstart') + INTERVAL FLOOR(RAND()*TIMESTAMPDIFF(SECOND,'$mstart','$mnext')) SECOND AS td
             FROM seq a CROSS JOIN seq b
             WHERE a.n < CEIL($rows/1000) AND a.n*1000 + b.n < $rows) d;"
    printf "\r  loaded month %d/%d" $((i+1)) $MONTHS
  done
  echo
  local t1=$(now_ms)
  q "SET sql_log_bin=0; INSERT INTO transaction_part SELECT * FROM transaction_plain;"
  local t2=$(now_ms)
  q "ANALYZE TABLE transaction_plain, transaction_part, card;" >/dev/null

  {
    echo "SETUP  ($(date -u '+%Y-%m-%d %H:%M UTC'), MySQL $(q 'SELECT VERSION()'))"
    echo "Rows per month            : $rows"
    echo "Rows per table            : $(q 'SELECT COUNT(*) FROM transaction_plain')"
    echo "Accounts                  : $ACCOUNTS"
    echo "Leaf partitions (part)    : $(q "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part'")"
    echo ".ibd files, plain table   : $(files_count 'transaction_plain*.ibd')"
    echo ".ibd files, partitioned   : $(files_count 'transaction_part#*.ibd')"
    echo "Disk size, plain table    : $(mb $(files_bytes 'transaction_plain*'))"
    echo "Disk size, partitioned    : $(mb $(files_bytes 'transaction_part*'))"
    echo "Load time plain           : $((t1-t0)) ms"
    echo "Copy time into partitioned: $((t2-t1)) ms"
    echo
    echo "Example partition files for one month:"
    local f; for f in "$DATADIR/$DB"/transaction_part#p#$(month 0 +p%Y_%m)#sp#*sp[0-3].ibd; do echo "  ${f##*/}"; done
  } | tee "$log"
}

# ---------------------------------------------------------------------
# errors : MySQL rules that shape the GlobalCard design (expected errors)
# ---------------------------------------------------------------------
errors() {
  local log="$OUT/errors.txt"
  local cols="transaction_id BIGINT NOT NULL, account_id BIGINT NOT NULL, transaction_type VARCHAR(20) NOT NULL, transaction_date TIMESTAMP NOT NULL"
  local p="(PARTITION p0 VALUES LESS THAN (UNIX_TIMESTAMP('2020-01-01 00:00:00')), PARTITION p1 VALUES LESS THAN MAXVALUE)"
  q "DROP TABLE IF EXISTS e1,e2,e3,e4,e_parent;"
  {
    echo "1) Keep the course primary key (transaction_id) and partition by date:"
    qerr "CREATE TABLE e1 ($cols, PRIMARY KEY (transaction_id)) PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) $p;"
    echo
    echo "2) Keep a foreign key on a partitioned table:"
    q "CREATE TABLE e_parent (account_id BIGINT PRIMARY KEY);"
    qerr "CREATE TABLE e2 ($cols, PRIMARY KEY (transaction_id, transaction_date), FOREIGN KEY (account_id) REFERENCES e_parent(account_id)) PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) $p;"
    echo
    echo "3) RANGE COLUMNS directly on the TIMESTAMP column transaction_date:"
    qerr "CREATE TABLE e3 ($cols, PRIMARY KEY (transaction_id, transaction_date)) PARTITION BY RANGE COLUMNS (transaction_date) (PARTITION p0 VALUES LESS THAN ('2020-01-01'), PARTITION p1 VALUES LESS THAN (MAXVALUE));"
    echo
    echo "4) Sub-partition by cardholder_id (the column is not on transaction):"
    qerr "CREATE TABLE e4 ($cols, PRIMARY KEY (transaction_id, transaction_date, account_id)) PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) SUBPARTITION BY HASH (cardholder_id) SUBPARTITIONS 4 $p;"
    echo
    echo "5) Subtype table (tx_purchase) referencing the partitioned transaction table:"
    qerr "CREATE TABLE e5 (transaction_id BIGINT PRIMARY KEY, transaction_date TIMESTAMP NOT NULL, account_id BIGINT NOT NULL, FOREIGN KEY (transaction_id, transaction_date, account_id) REFERENCES transaction_part (transaction_id, transaction_date, account_id));"
  } | tee "$log"
  q "DROP TABLE IF EXISTS e1,e2,e3,e4,e5,e_parent;"
}

# ---------------------------------------------------------------------
# measure LABEL SQL : run one statement and record time, redo, binlog, undo
# ---------------------------------------------------------------------
measure() {
  local label=$1 sql=$2
  local r0=$(status Innodb_os_log_written) b0=$(binlog_bytes) t0=$(now_ms)
  local res; res=$(qerr "$sql")
  local t1=$(now_ms) r1=$(status Innodb_os_log_written) b1=$(binlog_bytes)
  printf "%-40s time %8d ms | redo log %10s | binlog %10s\n" \
    "$label" $((t1-t0)) "$(mb $((r1-r0)))" "$(mb $((b1-b0)))"
  if [ -n "$res" ]; then echo "    -> $res"; fi
  return 0
}

# ---------------------------------------------------------------------
# problemA : purge the oldest month — DELETE vs DROP PARTITION vs EXCHANGE
# ---------------------------------------------------------------------
problemA() {
  local rows=$(q "SELECT ROUND(COUNT(*)/$MONTHS) FROM transaction_plain")
  local log="$OUT/problemA_${rows}_per_month.txt"
  local oldest=$(q "SELECT PARTITION_NAME FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME<>'p_future' ORDER BY PARTITION_ORDINAL_POSITION LIMIT 1")
  local second=$(q "SELECT PARTITION_NAME FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME<>'p_future' ORDER BY PARTITION_ORDINAL_POSITION LIMIT 1 OFFSET $SUBPARTS")
  local upper=$(q "SELECT PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME='$oldest' LIMIT 1")
  local n_old=$(q "SELECT COUNT(*) FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($upper)")
  {
    echo "PROBLEM A  ($(date -u '+%Y-%m-%d %H:%M UTC'))  ~$rows rows per month; purging $oldest ($n_old rows)"
    echo
    echo "Before:"
    echo "  plain table on disk        : $(mb $(files_bytes 'transaction_plain*'))"
    echo "  partitioned table on disk  : $(mb $(files_bytes 'transaction_part*'))"
    echo "  files for $oldest       : $(files_count "transaction_part#p#$oldest#*") .ibd files, $(mb $(files_bytes "transaction_part#p#$oldest#*"))"
    echo
    measure "DELETE oldest month (plain)" "DELETE FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($upper); SELECT CONCAT(ROW_COUNT(),' rows deleted');"
    measure "DROP PARTITION $oldest (part)" "ALTER TABLE transaction_part DROP PARTITION $oldest;"
    echo
    echo "After:"
    echo "  plain table on disk        : $(mb $(files_bytes 'transaction_plain*'))   (DATA_FREE inside file: $(mb $(q "SELECT DATA_FREE FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_plain'")))"
    echo "  partitioned table on disk  : $(mb $(files_bytes 'transaction_part*'))"
    echo "  files left for $oldest  : $(files_count "transaction_part#p#$oldest#*")"
    echo
    echo "EXCHANGE PARTITION (archive instead of destroy) on $second:"
    q "DROP TABLE IF EXISTS archive_tx; CREATE TABLE archive_tx LIKE transaction_part; ALTER TABLE archive_tx REMOVE PARTITIONING;"
    measure "EXCHANGE whole partition" "ALTER TABLE transaction_part EXCHANGE PARTITION $second WITH TABLE archive_tx WITHOUT VALIDATION;"
    measure "EXCHANGE ${second}sp0 out (no validation)" "ALTER TABLE transaction_part EXCHANGE PARTITION ${second}sp0 WITH TABLE archive_tx WITHOUT VALIDATION;"
    local arch=$(q 'SELECT COUNT(*) FROM archive_tx')
    echo "    rows now in archive_tx: $arch (and ${second}sp0 is empty)"
    measure "swap back WITH validation ($arch rows)" "ALTER TABLE transaction_part EXCHANGE PARTITION ${second}sp0 WITH TABLE archive_tx;"
    echo
    echo "Adding next month by splitting p_future:"
    local lastb=$(q "SELECT PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME<>'p_future' ORDER BY PARTITION_ORDINAL_POSITION DESC LIMIT 1")
    local nm=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb),'p%Y_%m')")
    local nb=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb) + INTERVAL 1 MONTH,'%Y-%m-01 00:00:00')")
    measure "REORGANIZE p_future -> $nm" "ALTER TABLE transaction_part REORGANIZE PARTITION p_future INTO (PARTITION $nm VALUES LESS THAN (UNIX_TIMESTAMP('$nb')), PARTITION p_future VALUES LESS THAN MAXVALUE);"
  } | tee "$log"
}

# ---------------------------------------------------------------------
# problemB : support-agent searches — how many partitions does MySQL touch?
# ---------------------------------------------------------------------
problemB() {
  local rows=$(q "SELECT ROUND(COUNT(*)/$MONTHS) FROM transaction_plain")
  local log="$OUT/problemB_${rows}_per_month.txt"
  local acc=${ACC:-4242}
  local ch=$(q "SELECT cardholder_id FROM card WHERE account_id=$acc LIMIT 1")
  local total=$(q "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part'")
  local last=$(q "SELECT MAX(transaction_date) FROM transaction_plain")
  local m1=$(q "SELECT DATE_FORMAT('$last','%Y-%m-01')")
  local m1e=$(q "SELECT DATE_FORMAT('$last' + INTERVAL 1 MONTH,'%Y-%m-01')")
  local y3=$(q "SELECT DATE_FORMAT('$last' - INTERVAL 35 MONTH,'%Y-%m-01')")

  local -a labels=( "account + 1 month" "account + 3 years" "account only (7 years)" "3 years, no account" "no partition key" "DATE_FORMAT on date (pitfall)" "cardholder via card (join)" )
  local -a wheres=(
    "account_id=$acc AND transaction_date >= '$m1' AND transaction_date < '$m1e'"
    "account_id=$acc AND transaction_date >= '$y3' AND transaction_date < '$m1e'"
    "account_id=$acc"
    "transaction_date >= '$y3' AND transaction_date < '$m1e' AND amount = 123.45"
    "amount = 123.45"
    "account_id=$acc AND DATE_FORMAT(transaction_date,'%Y-%m') = DATE_FORMAT('$m1','%Y-%m')"
    "JOIN"
  )
  {
    echo "PROBLEM B  ($(date -u '+%Y-%m-%d %H:%M UTC'))  ~$rows rows per month; account_id=$acc, cardholder_id=$ch"
    echo "Partitioned table has $total leaf partitions. Times are the best of 3 runs."
    echo
    printf "%-32s | %-22s | %-12s | %-12s\n" "Query" "Partitions read" "Partitioned" "Plain+index"
    printf -- "-%.0s" {1..86}; echo
    local i sqlp sqlx parts np tp tx s e best
    for i in "${!labels[@]}"; do
      if [ "${wheres[$i]}" = "JOIN" ]; then
        sqlp="SELECT t.* FROM card c JOIN transaction_part t ON t.account_id=c.account_id WHERE c.cardholder_id=$ch AND t.transaction_date >= '$y3' AND t.transaction_date < '$m1e'"
        sqlx="SELECT t.* FROM card c JOIN transaction_plain t ON t.account_id=c.account_id WHERE c.cardholder_id=$ch AND t.transaction_date >= '$y3' AND t.transaction_date < '$m1e'"
        parts=$(q "EXPLAIN $sqlp" | { local a b c d r; while IFS=$'\t' read -r a b c d r; do [ "$c" = t ] && echo "$d"; done; })
      else
        sqlp="SELECT * FROM transaction_part WHERE ${wheres[$i]}"
        sqlx="SELECT * FROM transaction_plain WHERE ${wheres[$i]}"
        parts=$(q "EXPLAIN $sqlp" | head -1 | cut -f4)
      fi
      if [ -z "$parts" ] || [ "$parts" = "NULL" ]; then np=0; else IFS=, read -ra arr <<< "$parts"; np=${#arr[@]}; fi
      for which in p x; do
        best=999999999
        for r in 1 2 3; do
          s=$(now_ms); if [ $which = p ]; then q "$sqlp" >/dev/null; else q "$sqlx" >/dev/null; fi; e=$(now_ms)
          (( e-s < best )) && best=$((e-s))
        done
        [ $which = p ] && tp=$best || tx=$best
      done
      printf "%-32s | %5d / %-5d (%7s) | %8d ms | %8d ms\n" "${labels[$i]}" "$np" "$total" "$(pct $np $total)" "$tp" "$tx"
    done
    echo
    echo "EXPLAIN for 'account + 3 years' on the partitioned table:"
    q "EXPLAIN SELECT * FROM transaction_part WHERE ${wheres[1]}" | {
      local id st tb pr ty pk ky kl rf rw rest
      IFS=$'\t' read -r id st tb pr ty pk ky kl rf rw rest
      IFS=, read -ra arr <<< "$pr"
      echo "  partitions: ${arr[0]}, ${arr[1]}, ${arr[2]} ... (${#arr[@]} in total)"
      echo "  access type: $ty   index used: $ky   rows estimate: $rw"
    }
  } | tee "$log"
}

case "${1:-}" in
  setup)    setup "${2:-50000}" ;;
  errors)   errors ;;
  problemA) problemA ;;
  problemB) problemB ;;
  *) echo "usage: bench.sh setup [rows_per_month] | errors | problemB | problemA" ;;
esac

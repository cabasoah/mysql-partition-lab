#!/bin/bash
# =====================================================================
# GlobalCard partitioning lab for MySQL (CS3543 term paper)  -- version 2
#
# Run inside the container (see README.md):
#   docker compose exec mysql bash /tests/bench.sh setup 20000
#   docker compose exec mysql bash /tests/bench.sh errors
#   docker compose exec mysql bash /tests/bench.sh problemB
#   docker compose exec mysql bash /tests/bench.sh problemA
#   docker compose exec mysql bash /tests/bench.sh locks
#   docker compose exec mysql bash /tests/bench.sh merchant
#   docker compose exec mysql bash /tests/bench.sh tiering
#
# Results are written to /results (the ./results folder on your computer).
# Needs only bash, coreutils and the mysql client.
# =====================================================================
set -uo pipefail
shopt -s nullglob

DB=${DB:-globalcard}
DATADIR=${DATADIR:-/var/lib/mysql}
OUT=${OUT:-/results}
COLD=${COLD:-/cold}               # second "cheap disk" directory used by the tiering test
ACCOUNTS=${ACCOUNTS:-100000}      # number of accounts the rows are spread over
START=${START:-2019-11-01}        # oldest retained month (84 months -> Oct 2026)
MONTHS=84
SUBPARTS=${SUBPARTS:-16}          # hash buckets per month (setup only; other steps read it back)
ACC=${ACC:-4242}                  # account used by the search tests
export MYSQL_PWD="${MYSQL_PWD:-${MYSQL_ROOT_PASSWORD:-rootpass}}"
MYSQL=${MYSQL:-"mysql -uroot"}

mkdir -p "$OUT"
q()      { $MYSQL -N -B "$DB" -e "$1"; }            # run SQL, tab-separated output
qerr()   { $MYSQL -N -B "$DB" -e "$1" 2>&1; }        # run SQL, keep error text
now_ms() { date +%s%3N; }
status() { q "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='$1'"; }
binlog_bytes() { $MYSQL -N -B -e "SHOW BINARY LOGS" | { local s=0 n sz r; while IFS=$'\t' read -r n sz r; do s=$((s+sz)); done; echo $s; }; }
apparent_bytes()  { local f=( $1 ); [ ${#f[@]} -eq 0 ] && { echo 0; return; }; du -cb "${f[@]}" | tail -1 | cut -f1; }
allocated_bytes() { local f=( $1 ); [ ${#f[@]} -eq 0 ] && { echo 0; return; }; du -c --block-size=1 "${f[@]}" | tail -1 | cut -f1; }
tbl_files()   { echo "$DATADIR/$DB/$1"; }
files_count() { local f=( $DATADIR/$DB/$1 ); echo ${#f[@]}; }
mb()     { local b=$1; printf "%d.%02d MB" $((b/1048576)) $(( (b%1048576)*100/1048576 )); }
pct()    { local x=$(( $1*10000/$2 )); printf "%d.%02d%%" $((x/100)) $((x%100)); }
month()  { date -u -d "$START +$1 month" "$2"; }
meta()   { q "SELECT v FROM lab_meta WHERE k='$1'"; }
median() { local s; mapfile -t s < <(printf '%s\n' "$@" | sort -n); echo "${s[$(( ${#s[@]} / 2 ))]}"; }
maxof()  { local s; mapfile -t s < <(printf '%s\n' "$@" | sort -n); echo "${s[$(( ${#s[@]} - 1 ))]}"; }
# n-th range partition of transaction_part (0 = oldest) and its upper bound
part_at()    { q "SELECT PARTITION_NAME FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME<>'p_future' GROUP BY PARTITION_NAME, PARTITION_ORDINAL_POSITION ORDER BY PARTITION_ORDINAL_POSITION LIMIT 1 OFFSET $1"; }
part_upper() { q "SELECT PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME='$1' LIMIT 1"; }
last_upper() { q "SELECT PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' AND PARTITION_NAME<>'p_future' ORDER BY PARTITION_ORDINAL_POSITION DESC LIMIT 1"; }
leaf_count() { q "SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$1'"; }
range_count(){ q "SELECT COUNT(DISTINCT PARTITION_NAME) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$1'"; }
tag()    { echo "$(meta rows_per_month)x$(meta subparts)"; }

TXCOLS="transaction_id BIGINT NOT NULL, account_id BIGINT NOT NULL,
       transaction_type VARCHAR(20) NOT NULL, amount DECIMAL(15,2) NOT NULL,
       transaction_date TIMESTAMP NOT NULL, posted_date TIMESTAMP NOT NULL,
       description VARCHAR(255) NOT NULL, is_disputed BOOLEAN NOT NULL DEFAULT FALSE"
# synthetic rows: $1 = id offset, $2 = month start, $3 = next month start, $4 = number of rows (<= 1,000,000)
gen_rows() {
  echo "SELECT id, acct, typ, amt, td, td + INTERVAL FLOOR(RAND()*3) DAY, 'synthetic transaction', RAND() < 0.0005
       FROM (SELECT $1 + a.n*1000 + b.n + 1 AS id,
                    1 + FLOOR(RAND()*$ACCOUNTS) AS acct,
                    ELT(1+FLOOR(RAND()*10),'PURCHASE','PURCHASE','PURCHASE','PURCHASE','PAYMENT','REFUND','FEE','INTEREST_CHARGE','CASH_ADVANCE','ADJUSTMENT') AS typ,
                    ROUND(RAND()*500,2) AS amt,
                    TIMESTAMP('$2') + INTERVAL FLOOR(RAND()*TIMESTAMPDIFF(SECOND,'$2','$3')) SECOND AS td
             FROM seq a CROSS JOIN seq b
             WHERE a.n < CEIL($4/1000) AND a.n*1000 + b.n < $4) d"
}

# ---------------------------------------------------------------------
# setup ROWS_PER_MONTH : build both tables and load identical data
#   SUBPARTS=n (env) sets the number of hash buckets per month (default 16, max 96)
# ---------------------------------------------------------------------
setup() {
  local rows=${1:-50000}
  if (( (MONTHS+1)*SUBPARTS > 8192 )); then echo "SUBPARTS=$SUBPARTS exceeds MySQL's 8192-partition limit (max 96)"; exit 1; fi
  local log="$OUT/setup_${rows}x${SUBPARTS}.txt"
  echo "Building tables: $rows rows per month x $MONTHS months, $SUBPARTS hash buckets per month..."

  local parts="" i name next
  for ((i=0; i<MONTHS; i++)); do
    name=$(month $i +p%Y_%m); next=$(month $((i+1)) +%Y-%m-01)
    parts+="PARTITION $name VALUES LESS THAN (UNIX_TIMESTAMP('$next 00:00:00')),"
  done
  parts+="PARTITION p_future VALUES LESS THAN MAXVALUE"

  q "DROP TABLE IF EXISTS transaction_part, transaction_plain, archive_tx, card, seq, lab_meta,
                          tx_purchase_idx, tx_purchase_hash, tier_demo, tier_archive;"
  q "CREATE TABLE lab_meta (k VARCHAR(30) PRIMARY KEY, v BIGINT);
     INSERT INTO lab_meta VALUES ('rows_per_month',$rows),('subparts',$SUBPARTS),('accounts',$ACCOUNTS);"
  q "CREATE TABLE seq (n INT PRIMARY KEY);
     INSERT INTO seq WITH RECURSIVE r(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM r WHERE n<999) SELECT n FROM r;"

  # (1) monolithic table: the course DDL (minus the FK to account) plus two helper indexes.
  #     ix_txdate lets the monthly DELETE find old rows without scanning the whole table,
  #     so the DELETE-vs-DROP comparison is fair to DELETE.
  q "CREATE TABLE transaction_plain ($TXCOLS,
       CONSTRAINT CHK_plain_type CHECK (transaction_type IN ('PURCHASE','CASH_ADVANCE','FEE','INTEREST_CHARGE','PAYMENT','REFUND','ADJUSTMENT')),
       PRIMARY KEY (transaction_id),
       UNIQUE KEY uq_identity (transaction_id, transaction_type, account_id),
       KEY ix_account_posted (account_id, posted_date),
       KEY ix_account_txdate (account_id, transaction_date),
       KEY ix_txdate (transaction_date)
     ) ENGINE=InnoDB;"

  # (2) partitioned table: RANGE by month, HASH(account_id) inside each month.
  q "CREATE TABLE transaction_part ($TXCOLS,
       CONSTRAINT CHK_part_type CHECK (transaction_type IN ('PURCHASE','CASH_ADVANCE','FEE','INTEREST_CHARGE','PAYMENT','REFUND','ADJUSTMENT')),
       PRIMARY KEY (transaction_id, transaction_date, account_id),
       UNIQUE KEY uq_identity (transaction_id, transaction_type, account_id, transaction_date),
       KEY ix_account_posted (account_id, posted_date),
       KEY ix_account_txdate (account_id, transaction_date)
     ) ENGINE=InnoDB
     PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date))
     SUBPARTITION BY HASH (account_id) SUBPARTITIONS $SUBPARTS
     ($parts);"

  # card table: routes a cardholder to account(s). About 30,000 cardholders hold two cards on two different accounts.
  q "CREATE TABLE card (card_id BIGINT PRIMARY KEY, account_id BIGINT NOT NULL, cardholder_id BIGINT NOT NULL,
       KEY ix_card_cardholder (cardholder_id), KEY ix_card_account (account_id)) ENGINE=InnoDB;
     INSERT INTO card SELECT a.n*1000+b.n+1, 1+((a.n*1000+b.n) % $ACCOUNTS), 1+((a.n*1000+b.n) % 119993)
       FROM seq a CROSS JOIN seq b WHERE a.n < 150;"

  local t0=$(now_ms) mstart mnext
  for ((i=0; i<MONTHS; i++)); do
    mstart=$(month $i +%Y-%m-01); mnext=$(month $((i+1)) +%Y-%m-01)
    q "SET sql_log_bin=0; INSERT INTO transaction_plain $(gen_rows $((i*10000000)) $mstart $mnext $rows);"
    printf "\r  loaded month %d/%d" $((i+1)) $MONTHS
  done
  echo
  local t1=$(now_ms)
  q "SET sql_log_bin=0; INSERT INTO transaction_part SELECT * FROM transaction_plain;"
  local t2=$(now_ms)
  q "ANALYZE TABLE transaction_plain, transaction_part, card;" >/dev/null

  local pf=( $(tbl_files 'transaction_part#*.ibd') ) smin=0 smax=0 f sz
  for f in "${pf[@]}"; do sz=$(stat -c %s "$f"); (( smin==0 || sz<smin )) && smin=$sz; (( sz>smax )) && smax=$sz; done
  {
    echo "SETUP  ($(date -u '+%Y-%m-%d %H:%M UTC'), MySQL $(q 'SELECT VERSION()'), buffer pool $(mb $(q 'SELECT @@innodb_buffer_pool_size')))"
    echo "Rows per month              : $rows"
    echo "Rows per table              : $(q 'SELECT COUNT(*) FROM transaction_plain')"
    echo "Accounts                    : $ACCOUNTS"
    echo "Hash buckets per month      : $SUBPARTS"
    echo "Leaf partitions (part)      : $(leaf_count transaction_part)"
    echo ".ibd files, plain / part    : $(files_count 'transaction_plain*.ibd') / $(files_count 'transaction_part#*.ibd')"
    echo "Plain table  (5 indexes)    : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_plain*.ibd')")), blocks allocated on disk $(mb $(allocated_bytes "$(tbl_files 'transaction_plain*.ibd')"))"
    echo "Partitioned  (4 indexes)    : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_part#*.ibd')")), blocks allocated on disk $(mb $(allocated_bytes "$(tbl_files 'transaction_part#*.ibd')"))"
    echo "  smallest / largest .ibd   : $(mb $smin) / $(mb $smax)"
    echo "  data + index pages in use : plain $(mb $(q "SELECT DATA_LENGTH+INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_plain'")), partitioned $(mb $(q "SELECT SUM(DATA_LENGTH+INDEX_LENGTH) FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part'"))"
    echo "Load time plain             : $((t1-t0)) ms"
    echo "Copy time into partitioned  : $((t2-t1)) ms"
    echo
    echo "Example partition files for one month:"
    for f in "$DATADIR/$DB"/transaction_part#p#$(month 0 +p%Y_%m)#sp#*sp[0-3].ibd; do echo "  ${f##*/}"; done
  } | tee "$log"
}

# ---------------------------------------------------------------------
# errors : MySQL rules that shape the GlobalCard design (expected errors)
# ---------------------------------------------------------------------
errors() {
  local log="$OUT/errors.txt"
  local cols="transaction_id BIGINT NOT NULL, account_id BIGINT NOT NULL, transaction_type VARCHAR(20) NOT NULL, transaction_date TIMESTAMP NOT NULL"
  local p="(PARTITION p0 VALUES LESS THAN (UNIX_TIMESTAMP('2020-01-01 00:00:00')), PARTITION p1 VALUES LESS THAN MAXVALUE)"
  q "DROP TABLE IF EXISTS e1,e2,e3,e4,e5,e6,e_parent;"
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
    echo
    echo "6) Range-List composite (LIST subpartitions under RANGE):"
    qerr "CREATE TABLE e6 ($cols, PRIMARY KEY (transaction_id, transaction_date, account_id)) PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) SUBPARTITION BY LIST (account_id) $p;"
    echo
    echo "7) transaction_id alone is no longer unique once the key is (transaction_id, transaction_date, account_id):"
    q "CREATE TABLE e1 ($cols, PRIMARY KEY (transaction_id, transaction_date, account_id)) PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) $p;"
    qerr "INSERT INTO e1 VALUES (1, 10, 'FEE', '2019-06-01 00:00:00'), (1, 10, 'FEE', '2021-06-01 00:00:00'); SELECT CONCAT('rows stored with transaction_id = 1: ', COUNT(*)) FROM e1 WHERE transaction_id = 1;"
  } | tee "$log"
  q "DROP TABLE IF EXISTS e1,e2,e3,e4,e5,e6,e_parent;"
}

# ---------------------------------------------------------------------
# measure LABEL SQL : run one statement; record time, redo, binlog.
#   Sets M_T (ms), M_R (redo bytes), M_B (binlog bytes), M_OUT (statement output)
# ---------------------------------------------------------------------
measure() {
  local label=$1 sql=$2
  local r0=$(status Innodb_os_log_written) b0=$(binlog_bytes) t0=$(now_ms)
  M_OUT=$(qerr "$sql")
  local t1=$(now_ms) r1=$(status Innodb_os_log_written) b1=$(binlog_bytes)
  M_T=$((t1-t0)); M_R=$((r1-r0)); M_B=$((b1-b0))
  printf "%-44s time %8d ms | redo log %10s | binlog %10s\n" "$label" $M_T "$(mb $M_R)" "$(mb $M_B)"
  if [ -n "$M_OUT" ]; then echo "    -> $M_OUT"; fi
  return 0
}

# ---------------------------------------------------------------------
# problemA : purge the three oldest months, one at a time —
#            DELETE vs DROP PARTITION, then EXCHANGE and REORGANIZE
# ---------------------------------------------------------------------
problemA() {
  local rows=$(meta rows_per_month) sub=$(meta subparts)
  local log="$OUT/problemA_$(tag).txt"
  local -a dt dr db pt pr pb
  local rep p up n
  {
    echo "PROBLEM A  ($(date -u '+%Y-%m-%d %H:%M UTC'))  $rows rows per month, $sub hash buckets per month, $(leaf_count transaction_part) leaf partitions"
    echo
    echo "Before:"
    echo "  plain table        : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_plain*.ibd')")), allocated $(mb $(allocated_bytes "$(tbl_files 'transaction_plain*.ibd')"))"
    echo "  partitioned table  : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_part#*.ibd')")), allocated $(mb $(allocated_bytes "$(tbl_files 'transaction_part#*.ibd')"))"
    p=$(part_at 0); up=$(part_upper $p)
    echo
    echo "How the DELETE finds its rows (EXPLAIN):"
    q "EXPLAIN DELETE FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($up)" | { local a b c d ty pk ky kl rf rw rest; IFS=$'\t' read -r a b c d ty pk ky kl rf rw rest; echo "  access type: $ty   index used: $ky   rows estimate: $rw"; }
    echo
    echo "If the DELETE fails part-way (DELETE inside a transaction, then ROLLBACK), month $p:"
    q "SET @t0=NOW(6); START TRANSACTION; DELETE FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($up);
       SET @n=ROW_COUNT(); SET @t1=NOW(6); ROLLBACK; SET @t2=NOW(6);
       SELECT CONCAT('  deleted ', @n, ' rows in ', ROUND(TIMESTAMPDIFF(MICROSECOND,@t0,@t1)/1000), ' ms, then ROLLBACK took ', ROUND(TIMESTAMPDIFF(MICROSECOND,@t1,@t2)/1000), ' ms');"
    echo
    echo "Purging the three oldest months, one at a time:"
    for rep in 1 2 3; do
      p=$(part_at 0); up=$(part_upper $p)
      n=$(files_count "transaction_part#p#$p#*")
      measure "run $rep  DELETE $p (plain table)" "DELETE FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($up); SELECT CONCAT(ROW_COUNT(),' rows deleted');"
      dt+=($M_T); dr+=($M_R); db+=($M_B)
      measure "run $rep  DROP PARTITION $p" "ALTER TABLE transaction_part DROP PARTITION $p;"
      pt+=($M_T); pr+=($M_R); pb+=($M_B)
      echo "    -> $n .ibd files before, $(files_count "transaction_part#p#$p#*") after"
    done
    echo
    echo "Median of the three runs:"
    printf "  %-16s time %8d ms | redo log %10s | binlog %10s\n" "DELETE" $(median "${dt[@]}") "$(mb $(median "${dr[@]}"))" "$(mb $(median "${db[@]}"))"
    printf "  %-16s time %8d ms | redo log %10s | binlog %10s\n" "DROP PARTITION" $(median "${pt[@]}") "$(mb $(median "${pr[@]}"))" "$(mb $(median "${pb[@]}"))"
    echo
    echo "After:"
    echo "  plain table        : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_plain*.ibd')")), allocated $(mb $(allocated_bytes "$(tbl_files 'transaction_plain*.ibd')"))   (free space inside the file: $(mb $(q "SELECT DATA_FREE FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_plain'")))"
    echo "  partitioned table  : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_part#*.ibd')")), allocated $(mb $(allocated_bytes "$(tbl_files 'transaction_part#*.ibd')"))"
    echo
    echo "Getting the DELETEd space back means rebuilding the whole plain table:"
    measure "OPTIMIZE TABLE transaction_plain" "SET sql_log_bin=0; OPTIMIZE TABLE transaction_plain;" | head -1
    echo "  plain table after  : file size $(mb $(apparent_bytes "$(tbl_files 'transaction_plain*.ibd')"))"
    echo
    p=$(part_at 0)
    echo "EXCHANGE PARTITION (archive instead of destroy) on $p:"
    q "DROP TABLE IF EXISTS archive_tx; CREATE TABLE archive_tx LIKE transaction_part; ALTER TABLE archive_tx REMOVE PARTITIONING;"
    measure "EXCHANGE whole partition $p" "ALTER TABLE transaction_part EXCHANGE PARTITION $p WITH TABLE archive_tx WITHOUT VALIDATION;"
    local s; local -a xo xb
    for s in 0 1 2; do
      (( s < sub )) || break
      measure "EXCHANGE ${p}sp$s out, no validation" "ALTER TABLE transaction_part EXCHANGE PARTITION ${p}sp$s WITH TABLE archive_tx WITHOUT VALIDATION;"; xo+=($M_T)
      n=$(q 'SELECT COUNT(*) FROM archive_tx')
      measure "  swap back WITH validation ($n rows)" "ALTER TABLE transaction_part EXCHANGE PARTITION ${p}sp$s WITH TABLE archive_tx;"; xb+=($M_T)
    done
    echo "  median: out without validation $(median "${xo[@]}") ms, back with validation $(median "${xb[@]}") ms; a full month needs $sub such statements"
    echo
    echo "Adding the next month by splitting p_future:"
    local lastb nm nb; local -a rt
    for rep in 1 2 3; do
      lastb=$(last_upper)
      nm=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb),'p%Y_%m')"); nb=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb) + INTERVAL 1 MONTH,'%Y-%m-01 00:00:00')")
      measure "REORGANIZE p_future -> $nm (empty)" "ALTER TABLE transaction_part REORGANIZE PARTITION p_future INTO (PARTITION $nm VALUES LESS THAN (UNIX_TIMESTAMP('$nb')), PARTITION p_future VALUES LESS THAN MAXVALUE);"; rt+=($M_T)
    done
    echo "  median of the three: $(median "${rt[@]}") ms"
    # the same split when the job runs late and p_future already holds rows
    lastb=$(last_upper)
    local ms=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb),'%Y-%m-01')") me=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb) + INTERVAL 1 MONTH,'%Y-%m-01')")
    nm=$(q "SELECT DATE_FORMAT(FROM_UNIXTIME($lastb),'p%Y_%m')")
    local late=$(( rows < 1000000 ? rows : 1000000 ))
    q "SET sql_log_bin=0; INSERT INTO transaction_part $(gen_rows 900000000000 $ms $me $late);"
    measure "REORGANIZE p_future -> $nm ($late rows)" "ALTER TABLE transaction_part REORGANIZE PARTITION p_future INTO (PARTITION $nm VALUES LESS THAN (UNIX_TIMESTAMP('$me 00:00:00')), PARTITION p_future VALUES LESS THAN MAXVALUE);"
  } | tee "$log"
}

# ---------------------------------------------------------------------
# problemB : support-agent searches — how many partitions does MySQL touch?
# ---------------------------------------------------------------------
problemB() {
  local rows=$(meta rows_per_month) sub=$(meta subparts)
  local log="$OUT/problemB_$(tag).txt"
  local acc=$ACC
  local ch=$(q "SELECT cardholder_id FROM card WHERE account_id=$acc LIMIT 1")
  local accs=$(q "SELECT GROUP_CONCAT(DISTINCT account_id ORDER BY account_id) FROM card WHERE cardholder_id=$ch")
  local total=$(leaf_count transaction_part) nrange=$(range_count transaction_part)
  local last=$(q "SELECT MAX(transaction_date) FROM transaction_plain WHERE transaction_id < 900000000000")
  local m1=$(q "SELECT DATE_FORMAT('$last','%Y-%m-01')")
  local m1e=$(q "SELECT DATE_FORMAT('$last' + INTERVAL 1 MONTH,'%Y-%m-01')")
  local y3=$(q "SELECT DATE_FORMAT('$last' - INTERVAL 35 MONTH,'%Y-%m-01')")
  local d3="transaction_date >= '$y3' AND transaction_date < '$m1e'"

  local -a labels=( "account + 1 month" "account + 3 years" "account only (7 years)" "3 years, no account" "no partition key"
                    "DATE_FORMAT on date (pitfall)" "cardholder via card (join), 3y" "cardholder: IN (accounts), 3y" )
  local -a wheres=(
    "account_id=$acc AND transaction_date >= '$m1' AND transaction_date < '$m1e'"
    "account_id=$acc AND $d3"
    "account_id=$acc"
    "$d3 AND amount = 123.45"
    "amount = 123.45"
    "account_id=$acc AND DATE_FORMAT(transaction_date,'%Y-%m') = DATE_FORMAT('$m1','%Y-%m')"
    "JOIN"
    "account_id IN ($accs) AND $d3"
  )
  local -a o_np o_tp o_tx o_rp o_rx o_px
  local i sqlp sqlx parts np s e best which r r0 path
  for i in "${!labels[@]}"; do
    if [ "${wheres[$i]}" = "JOIN" ]; then
      sqlp="SELECT t.* FROM card c JOIN transaction_part t ON t.account_id=c.account_id WHERE c.cardholder_id=$ch AND t.transaction_date >= '$y3' AND t.transaction_date < '$m1e'"
      sqlx="SELECT t.* FROM card c JOIN transaction_plain t ON t.account_id=c.account_id WHERE c.cardholder_id=$ch AND t.transaction_date >= '$y3' AND t.transaction_date < '$m1e'"
      parts=$(q "EXPLAIN $sqlp" | { local a b c d rr; while IFS=$'\t' read -r a b c d rr; do [ "$c" = t ] && echo "$d"; done; })
      path=$(q "EXPLAIN $sqlx" | { local a b c d ty pk ky rr; while IFS=$'\t' read -r a b c d ty pk ky rr; do [ "$c" = t ] && echo "$ty / $ky"; done; })
    else
      sqlp="SELECT * FROM transaction_part WHERE ${wheres[$i]}"
      sqlx="SELECT * FROM transaction_plain WHERE ${wheres[$i]}"
      parts=$(q "EXPLAIN $sqlp" | head -1 | cut -f4)
      path=$(q "EXPLAIN $sqlx" | head -1 | { local a b c d ty pk ky rr; IFS=$'\t' read -r a b c d ty pk ky rr; echo "$ty / $ky"; })
    fi
    if [ -z "$parts" ] || [ "$parts" = "NULL" ]; then np=0; else local arr; IFS=, read -ra arr <<< "$parts"; np=${#arr[@]}; fi
    for which in p x; do
      best=999999999
      for r in 1 2 3; do
        r0=$(status Innodb_buffer_pool_reads); s=$(now_ms)
        if [ $which = p ]; then q "$sqlp" >/dev/null; else q "$sqlx" >/dev/null; fi
        e=$(now_ms); (( e-s < best )) && best=$((e-s))
      done
      r=$(( $(status Innodb_buffer_pool_reads) - r0 ))        # pages read from disk during the last run
      if [ $which = p ]; then o_tp[$i]=$best; o_rp[$i]=$r; else o_tx[$i]=$best; o_rx[$i]=$r; fi
    done
    o_np[$i]=$np; o_px[$i]=$path
  done
  {
    echo "PROBLEM B  ($(date -u '+%Y-%m-%d %H:%M UTC'))  $rows rows per month, $sub hash buckets per month"
    echo "account_id=$acc; cardholder_id=$ch owns accounts: $accs"
    echo "Partitioned table: $nrange range partitions x $sub buckets = $total leaf partitions. Times are the best of 3 runs."
    echo
    printf "%-32s | %-24s | %-11s | %-11s\n" "Query" "Partitions read" "Partitioned" "Plain"
    printf -- "-%.0s" {1..88}; echo
    for i in "${!labels[@]}"; do
      printf "%-32s | %5d / %-5d (%7s) | %8d ms | %8d ms\n" "${labels[$i]}" "${o_np[$i]}" "$total" "$(pct ${o_np[$i]} $total)" "${o_tp[$i]}" "${o_tx[$i]}"
    done
    echo
    echo "Why the times differ: how the plain table is read, and pages read from disk in the last run"
    printf "%-32s | %-34s | %-12s | %-12s\n" "Query" "Plain table: access type / index" "Disk: part" "Disk: plain"
    printf -- "-%.0s" {1..98}; echo
    for i in "${!labels[@]}"; do
      printf "%-32s | %-34s | %6d pages | %6d pages\n" "${labels[$i]}" "${o_px[$i]}" "${o_rp[$i]}" "${o_rx[$i]}"
    done
    echo
    local read3=${o_np[1]}
    echo "The 99.9% question, for the 3-year account search:"
    echo "  it reads $read3 leaf partitions (one bucket in each month of the window), i.e. $(pct $read3 $total) of $total."
    echo "  to read at most 0.1% of the partitions, the table would need $((read3*1000)) leaf partitions = $(( (read3*1000 + nrange - 1) / nrange )) buckets per month."
    echo "  MySQL allows 8192 partitions in total, so at most $((8192/nrange)) buckets per month with $nrange range partitions (best case: $(pct $read3 $(( (8192/nrange)*nrange )) ) read)."
    echo
    echo "EXPLAIN for 'account + 3 years' on the partitioned table:"
    q "EXPLAIN SELECT * FROM transaction_part WHERE ${wheres[1]}" | {
      local id st tb pr ty pk ky kl rf rw rest arr
      IFS=$'\t' read -r id st tb pr ty pk ky kl rf rw rest
      IFS=, read -ra arr <<< "$pr"
      echo "  partitions: ${arr[0]}, ${arr[1]}, ${arr[2]} ... (${#arr[@]} in total)"
      echo "  access type: $ty   index used: $ky   rows estimate: $rw"
    }
  } | tee "$log"
}

# ---------------------------------------------------------------------
# locks : what other sessions experience during a DELETE and during a DROP PARTITION
#         (removes two more months from each table)
# ---------------------------------------------------------------------
PROBE_ID=9000000000000000
probe_once() {   # $1 = table ; prints "select_ms insert_ms"
  local s=$(now_ms); q "SELECT COUNT(*) FROM $1 WHERE account_id=$ACC AND transaction_date >= '$PROBE_MONTH'" >/dev/null
  local m=$(now_ms) id=$(( PROBE_ID + $(date +%s%N) % 90000000000000 ))   # unique id per probe
  q "SET sql_log_bin=0; INSERT INTO $1 VALUES ($id, $ACC, 'FEE', 1.00, '$PROBE_MONTH 12:00:00', '$PROBE_MONTH 12:00:00', 'lock probe', 0);" >/dev/null
  local e=$(now_ms); echo "$((m-s)) $((e-m))"
}
probe_while() {  # $1 = table, $2 = pid to watch ; fills P_SEL and P_INS arrays
  P_SEL=(); P_INS=(); local a b
  while kill -0 $2 2>/dev/null; do
    read -r a b <<< "$(probe_once $1)"; P_SEL+=($a); P_INS+=($b); sleep 0.1
  done
  if [ ${#P_SEL[@]} -eq 0 ]; then read -r a b <<< "$(probe_once $1)"; P_SEL+=($a); P_INS+=($b); fi
}
locks() {
  local rows=$(meta rows_per_month)
  local log="$OUT/locks_$(tag).txt"
  local last=$(q "SELECT MAX(transaction_date) FROM transaction_plain WHERE transaction_id < 900000000000")
  PROBE_MONTH=$(q "SELECT DATE_FORMAT('$last','%Y-%m-01')")
  local p1=$(part_at 0) p2=$(part_at 1)
  local up1=$(part_upper $p1) up2=$(part_upper $p2)
  local tmp="$OUT/.locktmp" a b i pid s e
  local -a base_s base_i
  {
    echo "LOCK TEST  ($(date -u '+%Y-%m-%d %H:%M UTC'))  $rows rows per month"
    echo "A second session runs one indexed SELECT and one INSERT for a recent month, over and over,"
    echo "while the purge runs. Each probe starts a new client, which is the baseline cost."
    echo
    for i in 1 2 3 4 5; do read -r a b <<< "$(probe_once transaction_plain)"; base_s+=($a); base_i+=($b); done
    echo "Baseline (nothing else running): SELECT median $(median "${base_s[@]}") ms, INSERT median $(median "${base_i[@]}") ms"
    echo
    echo "1) During DELETE of the two oldest months on the plain table ($p1, $p2):"
    s=$(now_ms)
    ( q "DELETE FROM transaction_plain WHERE transaction_date < FROM_UNIXTIME($up2)" ) & pid=$!
    sleep 0.3
    # a third session inserts a row dated inside the range being deleted
    ( s2=$(now_ms); q "SET SESSION innodb_lock_wait_timeout=3600; SET sql_log_bin=0; INSERT INTO transaction_plain VALUES (9100000000000001, $ACC, 'FEE', 1.00, FROM_UNIXTIME($up1) - INTERVAL 1 MONTH + INTERVAL 1 SECOND, FROM_UNIXTIME($up1), 'lock probe', 0);" >/dev/null 2>&1; echo $(( $(now_ms) - s2 )) > "$tmp" ) &
    local ipid=$!
    probe_while transaction_plain $pid; wait $pid; e=$(now_ms); wait $ipid
    echo "   DELETE ran for $((e-s)) ms; $(( ${#P_SEL[@]} )) probes completed while it ran"
    echo "   recent-month SELECT : median $(median "${P_SEL[@]}") ms, slowest $(maxof "${P_SEL[@]}") ms"
    echo "   recent-month INSERT : median $(median "${P_INS[@]}") ms, slowest $(maxof "${P_INS[@]}") ms"
    echo "   INSERT of a row dated inside the range being deleted: waited $(cat "$tmp") ms (started 300 ms after the DELETE)"
    echo
    echo "2) DROP PARTITION $p1 while another session has an open transaction on the table:"
    ( q "START TRANSACTION; SELECT COUNT(*) FROM transaction_part WHERE account_id=$ACC AND transaction_date >= '$PROBE_MONTH'; DO SLEEP(6); COMMIT;" >/dev/null ) & local hpid=$!
    sleep 1
    ( s2=$(now_ms); q "ALTER TABLE transaction_part DROP PARTITION $p1" >/dev/null 2>&1; echo $(( $(now_ms) - s2 )) > "$tmp" ) & pid=$!
    sleep 1
    s=$(now_ms); q "SELECT COUNT(*) FROM transaction_part WHERE account_id=$ACC AND transaction_date >= '$PROBE_MONTH'" >/dev/null; e=$(now_ms)
    wait $pid; wait $hpid
    echo "   the open transaction held the table for 6000 ms (the DROP was issued 1000 ms into it)"
    echo "   DROP PARTITION took $(cat "$tmp") ms in total, most of it waiting for that transaction to end"
    echo "   a new SELECT issued while the DROP was waiting took $((e-s)) ms (it queued behind the DROP)"
    echo
    echo "3) DROP PARTITION $p2 with no open transactions, probes running:"
    s=$(now_ms)
    ( q "ALTER TABLE transaction_part DROP PARTITION $p2" >/dev/null 2>&1 ) & pid=$!
    probe_while transaction_part $pid; wait $pid; e=$(now_ms)
    echo "   DROP ran for $((e-s)) ms; $(( ${#P_SEL[@]} )) probes completed while it ran"
    echo "   recent-month SELECT : median $(median "${P_SEL[@]}") ms, slowest $(maxof "${P_SEL[@]}") ms"
    echo "   recent-month INSERT : median $(median "${P_INS[@]}") ms, slowest $(maxof "${P_INS[@]}") ms"
  } | tee "$log"
  rm -f "$tmp"
  q "SET sql_log_bin=0; DELETE FROM transaction_plain WHERE transaction_id >= 9000000000000000; DELETE FROM transaction_part WHERE transaction_id >= 9000000000000000;"
}

# ---------------------------------------------------------------------
# merchant : merchant_id lives on tx_purchase. Compare two layouts for merchant searches:
#   tx_purchase_idx  : RANGE by month + local index (merchant_id, transaction_date)
#   tx_purchase_hash : RANGE by month + HASH(merchant_id) x 8 + the same local index
# ---------------------------------------------------------------------
merchant() {
  local rows=$(meta rows_per_month) msub=${MSUB:-8}
  local log="$OUT/merchant_$(tag).txt"
  local parts="" nm ds
  while IFS=$'\t' read -r nm ds; do
    [ -n "$parts" ] && parts+=","
    if [ "$ds" = "MAXVALUE" ]; then parts+="PARTITION $nm VALUES LESS THAN MAXVALUE"; else parts+="PARTITION $nm VALUES LESS THAN ($ds)"; fi
  done < <(q "SELECT PARTITION_NAME, PARTITION_DESCRIPTION FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='transaction_part' GROUP BY PARTITION_NAME, PARTITION_DESCRIPTION, PARTITION_ORDINAL_POSITION ORDER BY PARTITION_ORDINAL_POSITION")
  local cols="transaction_id BIGINT NOT NULL, transaction_date TIMESTAMP NOT NULL, account_id BIGINT NOT NULL, card_id BIGINT NOT NULL, merchant_id BIGINT NOT NULL, auth_code CHAR(6) NOT NULL"
  echo "Building tx_purchase tables from the PURCHASE rows of transaction_part ..."
  q "DROP TABLE IF EXISTS tx_purchase_idx, tx_purchase_hash;"
  q "CREATE TABLE tx_purchase_idx ($cols, PRIMARY KEY (transaction_id, transaction_date), KEY ix_merchant_date (merchant_id, transaction_date))
       ENGINE=InnoDB PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) ($parts);"
  q "CREATE TABLE tx_purchase_hash ($cols, PRIMARY KEY (transaction_id, transaction_date, merchant_id), KEY ix_merchant_date (merchant_id, transaction_date))
       ENGINE=InnoDB PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) SUBPARTITION BY HASH (merchant_id) SUBPARTITIONS $msub ($parts);"
  # 5% of purchases go to one very large merchant (id 1); the rest are spread over 50,000 merchants
  q "SET sql_log_bin=0; INSERT INTO tx_purchase_idx
       SELECT transaction_id, transaction_date, account_id, account_id, IF(RAND() < 0.05, 1, 2 + FLOOR(RAND()*50000)), 'A1B2C3'
       FROM transaction_part WHERE transaction_type='PURCHASE';"
  q "SET sql_log_bin=0; INSERT INTO tx_purchase_hash SELECT * FROM tx_purchase_idx; ANALYZE TABLE tx_purchase_idx, tx_purchase_hash;" >/dev/null
  local last=$(q "SELECT MAX(transaction_date) FROM tx_purchase_idx WHERE transaction_id < 900000000000")
  local m1=$(q "SELECT DATE_FORMAT('$last','%Y-%m-01')") m1e=$(q "SELECT DATE_FORMAT('$last' + INTERVAL 1 MONTH,'%Y-%m-01')") y3=$(q "SELECT DATE_FORMAT('$last' - INTERVAL 35 MONTH,'%Y-%m-01')")
  local lastp=$(q "SELECT DATE_FORMAT('$last','p%Y_%m')")
  local ti=$(leaf_count tx_purchase_idx) th=$(leaf_count tx_purchase_hash)
  local -a labels=( "small merchant + 1 month" "small merchant + 3 years" "small merchant only" "large merchant + 1 month" )
  local -a wheres=(
    "merchant_id=4242 AND transaction_date >= '$m1' AND transaction_date < '$m1e'"
    "merchant_id=4242 AND transaction_date >= '$y3' AND transaction_date < '$m1e'"
    "merchant_id=4242"
    "merchant_id=1 AND transaction_date >= '$m1' AND transaction_date < '$m1e'"
  )
  {
    echo "MERCHANT SEARCH  ($(date -u '+%Y-%m-%d %H:%M UTC'))  $rows rows per month; $(q 'SELECT COUNT(*) FROM tx_purchase_idx') purchase rows"
    echo "  tx_purchase_idx  : RANGE by month, local index (merchant_id, transaction_date); $ti leaf partitions"
    echo "  tx_purchase_hash : RANGE by month + HASH(merchant_id) x $msub, same index; $th leaf partitions"
    echo "  Times are the best of 3 runs; 'rows' is the number of rows returned."
    echo
    printf "%-26s | %-7s | %-22s | %-22s\n" "Query" "rows" "Index only: parts / ms" "Hash: parts / ms"
    printf -- "-%.0s" {1..88}; echo
    local i t sql parts np s e best r cnt; local -a onp obt
    for i in "${!labels[@]}"; do
      cnt=$(q "SELECT COUNT(*) FROM tx_purchase_idx WHERE ${wheres[$i]}")
      for t in tx_purchase_idx tx_purchase_hash; do
        sql="SELECT * FROM $t WHERE ${wheres[$i]}"
        parts=$(q "EXPLAIN $sql" | head -1 | cut -f4); local arr; IFS=, read -ra arr <<< "$parts"; np=${#arr[@]}
        best=999999999; for r in 1 2 3; do s=$(now_ms); q "$sql" >/dev/null; e=$(now_ms); (( e-s < best )) && best=$((e-s)); done
        if [ $t = tx_purchase_idx ]; then onp[0]=$np; obt[0]=$best; else onp[1]=$np; obt[1]=$best; fi
      done
      printf "%-26s | %7d | %6d of %-5d %6d ms | %6d of %-5d %6d ms\n" "${labels[$i]}" "$cnt" "${onp[0]}" "$ti" "${obt[0]}" "${onp[1]}" "$th" "${obt[1]}"
    done
    echo
    echo "Hash skew caused by the large merchant (rows per bucket in $lastp of tx_purchase_hash):"
    q "SELECT CONCAT('  smallest bucket ', MIN(c), ' rows, largest bucket ', MAX(c), ' rows') FROM (SELECT COUNT(*) c FROM tx_purchase_hash WHERE transaction_date >= '$m1' AND transaction_date < '$m1e' GROUP BY MOD(merchant_id, $msub)) x"
    echo
    echo "A merchant search usually needs the amount, which is on transaction, so it joins back:"
    sql="SELECT t.transaction_id, t.amount FROM tx_purchase_idx p JOIN transaction_part t ON t.transaction_id=p.transaction_id AND t.transaction_date=p.transaction_date AND t.account_id=p.account_id WHERE p.merchant_id=4242 AND p.transaction_date >= '$m1' AND p.transaction_date < '$m1e'"
    parts=$(q "EXPLAIN $sql" | { local a b c d rr; while IFS=$'\t' read -r a b c d rr; do [ "$c" = t ] && echo "$d"; done; }); IFS=, read -ra arr <<< "$parts"
    best=999999999; for r in 1 2 3; do s=$(now_ms); q "$sql" >/dev/null; e=$(now_ms); (( e-s < best )) && best=$((e-s)); done
    echo "  small merchant + 1 month, joined to transaction_part: EXPLAIN lists ${#arr[@]} of $(leaf_count transaction_part) partitions of transaction_part; $best ms"
    echo "  (MySQL carries the date range across the join, but not account_id, so every bucket of the month is listed)"
  } | tee "$log"
}

# ---------------------------------------------------------------------
# tiering : place partitions on a second directory ($COLD), move one, and compress an archive
#   needs the server started with --innodb-directories=/cold (see docker-compose.yml)
# ---------------------------------------------------------------------
tiering() {
  local log="$OUT/tiering.txt"
  local dirs=$(q "SELECT @@innodb_directories")
  if [[ "$dirs" != *"$COLD"* ]] || [ ! -d "$COLD" ]; then
    echo "The tiering test needs a second directory known to InnoDB."
    echo "  innodb_directories is currently: '${dirs}'  and $COLD $( [ -d "$COLD" ] && echo exists || echo 'does not exist')"
    echo "  Use the docker-compose.yml from version 2 of this lab, then run: docker compose up -d"
    exit 1
  fi
  local small=${1:-50000} big
  big=$((small*4))
  q "DROP TABLE IF EXISTS tier_demo, tier_archive;"
  {
    echo "STORAGE TIERING  ($(date -u '+%Y-%m-%d %H:%M UTC'))  fast directory = $DATADIR, cheap directory = $COLD"
    echo
    echo "1) Create a table with one month placed on the cheap directory from the start:"
    q "CREATE TABLE tier_demo ($TXCOLS, PRIMARY KEY (transaction_id, transaction_date, account_id), KEY ix_account_txdate (account_id, transaction_date))
       ENGINE=InnoDB PARTITION BY RANGE (UNIX_TIMESTAMP(transaction_date)) (
         PARTITION p2030_01 VALUES LESS THAN (UNIX_TIMESTAMP('2030-02-01 00:00:00')) DATA DIRECTORY = '$COLD',
         PARTITION p2030_02 VALUES LESS THAN (UNIX_TIMESTAMP('2030-03-01 00:00:00')),
         PARTITION p2030_03 VALUES LESS THAN (UNIX_TIMESTAMP('2030-04-01 00:00:00')),
         PARTITION p_future VALUES LESS THAN MAXVALUE);"
    q "SET sql_log_bin=0; INSERT INTO tier_demo $(gen_rows 0 2030-01-01 2030-02-01 1000);
       INSERT INTO tier_demo $(gen_rows 10000000 2030-02-01 2030-03-01 $small);
       INSERT INTO tier_demo $(gen_rows 20000000 2030-03-01 2030-04-01 $big);"
    local f
    echo "   files under $COLD/$DB:";    for f in "$COLD/$DB"/tier_demo*; do echo "     ${f##*/}  ($(mb $(stat -c %s "$f")))"; done
    echo "   files under $DATADIR/$DB:"; for f in "$DATADIR/$DB"/tier_demo*; do echo "     ${f##*/}  ($(mb $(stat -c %s "$f")))"; done
    echo
    echo "2) Move existing months to the cheap directory (REORGANIZE PARTITION ... DATA DIRECTORY):"
    measure "move p2030_02 ($small rows)" "ALTER TABLE tier_demo REORGANIZE PARTITION p2030_02 INTO (PARTITION p2030_02 VALUES LESS THAN (UNIX_TIMESTAMP('2030-03-01 00:00:00')) DATA DIRECTORY = '$COLD');"
    measure "move p2030_03 ($big rows)" "ALTER TABLE tier_demo REORGANIZE PARTITION p2030_03 INTO (PARTITION p2030_03 VALUES LESS THAN (UNIX_TIMESTAMP('2030-04-01 00:00:00')) DATA DIRECTORY = '$COLD');"
    echo "   files under $COLD/$DB now:";    for f in "$COLD/$DB"/tier_demo*; do echo "     ${f##*/}  ($(mb $(stat -c %s "$f")))"; done
    echo "   files left under $DATADIR/$DB:"; for f in "$DATADIR/$DB"/tier_demo*; do echo "     ${f##*/}  ($(mb $(stat -c %s "$f")))"; done
    echo
    echo "3) Archive tier: exchange a month out to a standalone table, then compress it:"
    q "CREATE TABLE tier_archive LIKE tier_demo; ALTER TABLE tier_archive REMOVE PARTITIONING;"
    measure "EXCHANGE p2030_03 out ($big rows)" "ALTER TABLE tier_demo EXCHANGE PARTITION p2030_03 WITH TABLE tier_archive WITHOUT VALIDATION;"
    local before=$(q "SELECT FILE_SIZE FROM information_schema.INNODB_TABLESPACES WHERE NAME='$DB/tier_archive'")
    measure "compress archive (KEY_BLOCK_SIZE=8)" "SET sql_log_bin=0; ALTER TABLE tier_archive ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8;"
    local after=$(q "SELECT FILE_SIZE FROM information_schema.INNODB_TABLESPACES WHERE NAME='$DB/tier_archive'")
    echo "   archive table size: $(mb $before) -> $(mb $after)"
    echo "   (synthetic rows repeat the same description text, so real data will compress less)"
  } | tee "$log"
}

case "${1:-}" in
  setup)    setup "${2:-50000}" ;;
  errors)   errors ;;
  problemA) problemA ;;
  problemB) problemB ;;
  locks)    locks ;;
  merchant) merchant ;;
  tiering)  tiering "${2:-50000}" ;;
  *) echo "usage: bench.sh setup [rows_per_month] | errors | problemB | problemA | locks | merchant | tiering" ;;
esac

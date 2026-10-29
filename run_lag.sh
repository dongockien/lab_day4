#!/bin/bash
# Thi nghiem A: do replication lag o 2 kich ban con thieu (delay 2s, tam dung replay).
SQL="SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"

set_delay() {
  docker compose exec -T replica psql -U postgres -c "ALTER SYSTEM SET recovery_min_apply_delay = '$1';" > /dev/null
  docker compose exec -T replica psql -U postgres -c "SELECT pg_reload_conf();" > /dev/null
  sleep 2
}

measure() {
  docker compose exec -T primary pgbench -U postgres -c 4 -T 30 postgres > "pgbench_out_$1.txt" 2>&1 &
  sleep 5
  for i in 1 2 3 4 5; do
    docker compose exec -T primary psql -U postgres -c "$SQL"
    sleep 3
  done
  wait
  echo "--- pgbench ($1) ---"
  grep -E "tps|latency" "pgbench_out_$1.txt"
}

echo "=== Kich ban 2: delay = 2s ==="
set_delay 2s
measure delay2s

echo "=== Kich ban 3: tam dung replay (delay = 0) ==="
set_delay 0
docker compose exec -T replica psql -U postgres -c "SELECT pg_wal_replay_pause();"
measure pause
docker compose exec -T replica psql -U postgres -c "SELECT pg_wal_replay_resume();"
sleep 5
echo "=== Xong. Da noi lai replay, delay = 0 ==="

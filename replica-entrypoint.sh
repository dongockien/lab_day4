#!/bin/bash
set -e
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h primary -U postgres; do sleep 1; done
  
  # Vòng lặp retry pg_basebackup chống race condition
  until PGPASSWORD=repl_pass pg_basebackup -h primary -U replicator \
        -D "$PGDATA" -R -X stream -S replica1 -P; do
    echo "Primary chưa sẵn sàng cho replication, thử lại sau 2 giây..."
    sleep 2
  done
  
  chmod 700 "$PGDATA"
fi
exec postgres -c hot_standby=on -c max_connections=20
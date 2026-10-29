#!/bin/bash
# Chạy thí nghiệm B tự động: delay = 0 rồi delay = 2s, cuối cùng trả delay về 0.
set_delay() {
  docker compose exec -T replica psql -U postgres -c "ALTER SYSTEM SET recovery_min_apply_delay = '$1';" > /dev/null
  docker compose exec -T replica psql -U postgres -c "SELECT pg_reload_conf();" > /dev/null
  sleep 2
}

echo "=== Lan 1: delay = 0 ==="
set_delay 0
python ryw.py

echo "=== Lan 2: delay = 2s (mat khoang 2 phut) ==="
set_delay 2s
python ryw.py

set_delay 0
echo "=== Xong. Da tra delay ve 0 ==="

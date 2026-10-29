# Lab Ngày 4: PostgreSQL Replication và PgBouncer

Lab chạy bằng Docker Compose gồm một primary, một replica (streaming replication) và PgBouncer. Ba thí nghiệm tái hiện bằng số liệu:

| | Thí nghiệm | Mục tiêu |
|---|---|---|
| **A** | Đo replication lag | Phân biệt `write_lag`, `flush_lag`, `replay_lag` trong `pg_stat_replication` |
| **B** | Read-your-writes | Tái hiện lỗi ghi primary rồi đọc ngay replica không thấy dữ liệu, và kiểm chứng cách sửa bằng LSN |
| **C** | Connection pool | Hạ `max_connections` xuống 20, bắn 200 client, so sánh có và không có PgBouncer |

Phân tích lý thuyết và kết quả đầy đủ nằm trong báo cáo `ngay4_database_replica_pool_sharding.html`.

## Kiến trúc

```
                      ┌────────────── Docker network (lab_day4_default) ──────────────┐
 host :5432 ────────► │ primary   (postgres:16, max_connections=20)                   │
 host :5433 ────────► │ replica   (postgres:16, hot_standby, max_connections=20)      │
 host :6432 ────────► │ pgbouncer (transaction mode, default_pool_size=10) ─► primary │
                      └────────────────────────────────────────────────────────────────┘
                      primary ──WAL streaming (slot replica1)──► replica
```

| Thành phần | Cấu hình chính |
|---|---|
| primary | `wal_level=replica`, `max_wal_senders=10`, `max_replication_slots=10`, `max_connections=20` |
| replica | Tạo bằng `pg_basebackup -R`, replication slot `replica1`, `hot_standby=on`, `max_connections=20` |
| pgbouncer | `POOL_MODE=transaction`, `DEFAULT_POOL_SIZE=10`, `MAX_CLIENT_CONN=1000` |

Tài khoản chỉ dùng cho lab (không dùng cho môi trường thật):

| Tài khoản | Mật khẩu | Dùng cho |
|---|---|---|
| `postgres` | `secret` | Kết nối thường và pgbench |
| `replicator` | `repl_pass` | Replication |

## Cấu trúc thư mục

```
.
├── docker-compose.yml      # primary + replica + pgbouncer
├── init-primary.sh         # tạo role replicator, replication slot, bảng orders
├── replica-entrypoint.sh   # pg_basebackup từ primary rồi chạy ở chế độ replica
├── ryw.py                  # thí nghiệm B: so sánh đọc replica ngay sau ghi (naive và with_lsn)
├── run_ryw.sh              # chạy ryw.py ở delay = 0 và delay = 2s, tự trả delay về 0
└── run_lag.sh              # thí nghiệm A: đo lag ở delay = 2s và khi tạm dừng replay
```

## Yêu cầu

- Docker và Docker Compose v2 (lệnh `docker compose`)
- Python 3 và thư viện psycopg: `pip install "psycopg[binary]"`
- Bash (Git Bash trên Windows, hoặc terminal Linux/macOS)
- Các cổng 5432, 5433, 6432 trên máy host chưa bị chiếm

> Các cổng được publish ra máy host. Chỉ chạy lab trên máy cá nhân hoặc mạng tin cậy; muốn giới hạn thì đổi mapping thành `127.0.0.1:5432:5432` (tương tự cho 5433, 6432) trong `docker-compose.yml`.

## Khởi động

```bash
docker compose up -d
```

Kiểm tra replication hoạt động:

```bash
docker compose exec primary psql -U postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

Kết quả đúng: 1 dòng, `state = streaming`, `sync_state = async`.

Kiểm tra `max_connections`:

```bash
docker compose exec primary psql -U postgres -c "SHOW max_connections;"   # 20
```

Tạo dữ liệu cho pgbench (chạy một lần):

```bash
docker compose exec primary pgbench -U postgres -i -s 10 postgres
```

## Thí nghiệm A: Replication lag

Lag chỉ có giá trị khi **đang có tải ghi**. Không có tải ghi thì các cột `write_lag`, `flush_lag`, `replay_lag` trả về NULL (ô trống).

**Kịch bản 1: delay = 0.** Chạy tải ghi nền 30 giây và đo 5 lần:

```bash
SQL="SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"

docker compose exec -T primary pgbench -U postgres -c 4 -T 30 postgres > pgbench_out.txt &
sleep 5
for i in 1 2 3 4 5; do
  docker compose exec -T primary psql -U postgres -c "$SQL"
  sleep 3
done
wait
```

**Kịch bản 2 (delay = 2s) và 3 (tạm dừng replay):** chạy script, mất khoảng 2 phút:

```bash
bash run_lag.sh
```

Script tự đặt `recovery_min_apply_delay = '2s'`, đo, sau đó đặt về 0, gọi `pg_wal_replay_pause()`, đo, rồi `pg_wal_replay_resume()`. Kết quả pgbench của từng kịch bản lưu ở `pgbench_out_delay2s.txt` và `pgbench_out_pause.txt`.

## Thí nghiệm B: Read-your-writes

```bash
bash run_ryw.sh
```

Script chạy `ryw.py` hai lần (delay = 0 rồi delay = 2s) và trả delay về 0 khi xong. Mất khoảng 2–3 phút vì ở delay = 2s mỗi lần ghi phải chờ khoảng 2 giây.

`ryw.py` thực hiện hai phép thử, mỗi phép 50 lần ghi vào bảng `orders` trên primary (cổng 5432):

| Hàm | Cách đọc lại | Ý nghĩa |
|---|---|---|
| `naive` | Đọc ngay từ replica (cổng 5433) | Mô phỏng endpoint đọc replica sau khi ghi. In số lần không thấy dữ liệu |
| `with_lsn` | Lấy `pg_current_wal_lsn()` sau khi ghi, chờ tới khi `pg_last_wal_replay_lsn()` của replica đạt LSN đó (tối đa 5 giây) rồi mới đọc; quá hạn thì đọc primary | Cách sửa. In số lần fallback và thời gian chờ trung bình |

Đặt delay thủ công (nếu cần chạy `ryw.py` riêng) bằng hai lệnh tách rời:

```bash
docker compose exec replica psql -U postgres -c "ALTER SYSTEM SET recovery_min_apply_delay = '2s';"
docker compose exec replica psql -U postgres -c "SELECT pg_reload_conf();"
python ryw.py
```

Mỗi dòng kết quả in kèm giá trị delay đang dùng, ví dụ `[delay=2s] naive: ...`.

## Thí nghiệm C: Connection pool

`max_connections = 20` trên cả hai node. PgBouncer lắng nghe cổng 6432 trên máy host, nhưng bên trong mạng Docker nó lắng nghe cổng 5432. Vì vậy pgbench qua PgBouncer được chạy từ một container tạm cùng mạng. Tên mạng thường là `<tên-thư-mục>_default` (xem bằng `docker network ls`; bên dưới giả định `lab_day4_default`).

Biến `MSYS_NO_PATHCONV=1` chỉ cần trên Git Bash/Windows, để shell không đổi đường dẫn `/tmp`.

**C1. Không PgBouncer, 200 client.** Kỳ vọng: lỗi `FATAL: sorry, too many clients already`, pgbench dừng.

```bash
docker compose exec primary pgbench -h localhost -p 5432 -U postgres -c 200 -j 4 -T 10 -S -n postgres
```

**C2. Có PgBouncer, 200 client.** Kỳ vọng: 0 lỗi.

```bash
MSYS_NO_PATHCONV=1 docker run --rm --network lab_day4_default -e PGPASSWORD=secret postgres:16 \
  pgbench -h pgbouncer -p 5432 -U postgres -c 200 -j 4 -T 10 -S -n postgres
```

**C3. Đối chứng: nối thẳng 15 client.** Phải tắt PgBouncer trước, vì PgBouncer giữ 10 trong 20 kết nối của Postgres:

```bash
docker compose stop pgbouncer
docker compose exec primary pgbench -U postgres -c 15 -j 4 -T 30 -S -n postgres
docker compose start pgbouncer
```

**C4. Query giữ kết nối lâu, qua PgBouncer.** Đổi `SLEEP` giữa `0.05` và `0.5`:

```bash
SLEEP=0.5
MSYS_NO_PATHCONV=1 docker run --rm --network lab_day4_default -e PGPASSWORD=secret postgres:16 bash -c \
  "echo 'SELECT pg_sleep($SLEEP);' > /tmp/s.sql && pgbench -h pgbouncer -p 5432 -U postgres -c 200 -T 30 -n -f /tmp/s.sql postgres"
```

Trong lúc C4 đang chạy, mở terminal khác và xem trạng thái hàng đợi (chạy trong vài giây đầu):

```bash
MSYS_NO_PATHCONV=1 docker run --rm --network lab_day4_default -e PGPASSWORD=secret postgres:16 \
  psql -h pgbouncer -p 5432 -U postgres pgbouncer -c "SHOW POOLS;"
```

Các cột cần đọc: `cl_active`, `cl_waiting` (client đang xếp hàng), `sv_active`, `maxwait`. Trần throughput lý thuyết là `default_pool_size ÷ thời gian mỗi query` (10 ÷ 0,05 = 200 TPS; 10 ÷ 0,5 = 20 TPS).

Xem số kết nối PgBouncer đang giữ trên Postgres:

```bash
docker compose exec primary psql -U postgres -c \
  "SELECT application_name, client_addr, count(*) FROM pg_stat_activity WHERE backend_type='client backend' GROUP BY 1,2;"
```

## Kết quả đã đo

Môi trường: Windows, Docker Desktop, Git Bash, PostgreSQL 16.15. Chạy cục bộ nên chỉ dùng để so sánh tương đối, không phải benchmark.

**A. Replication lag** (tải ghi 4 client, 5 lần đo mỗi kịch bản)

| Kịch bản | write_lag | flush_lag | replay_lag | lag_bytes |
|---|---|---|---|---|
| delay = 0 | 0,07–0,52 ms | 0,15–0,91 ms | 0,15–1,66 ms | 8.952–44.128 |
| delay = 2s | 0,15–0,49 ms | 0,15–1,05 ms | 1,985–1,999 s | 1,5–5,2 triệu |
| Tạm dừng replay | 0,07–0,29 ms | 0,07–0,86 ms | 5,3 → 21,3 s (tăng liên tục) | 4,7 → 14,1 triệu |

**B. Read-your-writes** (n = 50)

| Cấu hình | `naive`: không thấy dữ liệu | `with_lsn`: fallback | `with_lsn`: chờ trung bình |
|---|---|---|---|
| delay = 0 | 2/50 | 0/50 | 1 ms |
| delay = 2s | 50/50 | 0/50 | 1.975 ms |

**C. Connection pool** (`max_connections = 20`)

| Kịch bản | TPS | Latency trung bình | Lỗi |
|---|---|---|---|
| Nối thẳng, 15 client, `-S`, 30 s | 47.478 | 0,316 ms | 0 |
| Nối thẳng, 200 client, `-S` | không có | không có | `too many clients already` |
| PgBouncer, 200 client, `-S`, 10 s | 30.362 | 6,587 ms | 0 |
| PgBouncer, 200 client, `pg_sleep(0.05)`, 30 s | 197,5 | 1.012,7 ms | 0 |
| PgBouncer, 200 client, `pg_sleep(0.5)`, 30 s | 19,9 | 10.039,7 ms | 0 |

`SHOW POOLS` khi chạy `pg_sleep(0.5)`: `cl_active = 10`, `cl_waiting = 190`, `sv_active = 10`, `maxwait ≈ 6,1 s`. Sau các lần chạy qua PgBouncer, `pg_stat_activity` cho thấy 10 kết nối thuộc PgBouncer trong tổng 20.

## Xử lý lỗi thường gặp

| Hiện tượng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `ALTER SYSTEM cannot run inside a transaction block` | Gộp `ALTER SYSTEM` và `SELECT pg_reload_conf()` trong một `psql -c` | Tách thành hai lệnh `-c` riêng |
| `Connection refused` ở `localhost:6432` khi chạy pgbench bằng `docker compose exec primary` | Cổng 6432 chỉ có trên máy host, không có bên trong container `primary` | Dùng container tạm cùng mạng Docker như ở thí nghiệm C |
| `too many clients already` ở bài đối chứng 15 client | PgBouncer đang giữ 10 kết nối thật | `docker compose stop pgbouncer` trước khi đo, `start` lại sau |
| `write_lag`, `flush_lag`, `replay_lag` trống | Không có tải ghi trên primary | Đo trong lúc `pgbench` ghi đang chạy |
| `docker: invalid reference format: repository name ... must be lowercase` | Biến chứa tên mạng chưa được gán, hoặc thiếu tên image | Viết thẳng tên mạng (`lab_day4_default`) trong lệnh |
| Script `.sh` báo `$'\r': command not found` | File bị đổi sang CRLF khi clone trên Windows | Chuyển về LF (`dos2unix run_*.sh`) hoặc cấu hình `.gitattributes` với `*.sh text eol=lf` |
| `ryw.py` báo `NameError: name 'cat' is not defined` | Dán lệnh tạo file vào bên trong `ryw.py` | Dùng đúng nội dung `ryw.py` trong repo |

## Dọn dẹp

Dừng cụm và giữ dữ liệu:

```bash
docker compose down
```

Xóa cả dữ liệu (volume) để chạy lại từ đầu:

```bash
docker compose down -v
```

Các file `pgbench_out*.txt` sinh ra khi chạy thí nghiệm A là kết quả tạm, không cần đưa vào repo.
# lab_day4

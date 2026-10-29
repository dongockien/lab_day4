import time
import psycopg

P = "host=localhost port=5432 user=postgres password=secret dbname=postgres"
R = "host=localhost port=5433 user=postgres password=secret dbname=postgres"


def naive(n=50):
    """Ghi vào primary rồi đọc ngay từ replica, giống endpoint 'Gói của tôi' đọc replica."""
    miss = 0
    with psycopg.connect(P, autocommit=True) as p, psycopg.connect(R, autocommit=True) as r:
        d = r.execute("SHOW recovery_min_apply_delay").fetchone()[0]
        for i in range(n):
            id_ = p.execute(
                "INSERT INTO orders(note) VALUES (%s) RETURNING id", (f"t{i}",)
            ).fetchone()[0]
            if r.execute("SELECT 1 FROM orders WHERE id=%s", (id_,)).fetchone() is None:
                miss += 1
    print(f"[delay={d}] naive: {miss}/{n} lần KHÔNG thấy dữ liệu vừa ghi trên replica")


def with_lsn(n=50, timeout=5.0):
    """Cách sửa: chờ replica replay tới LSN của lần ghi; quá hạn thì đọc primary."""
    fallback = 0
    waits = []
    with psycopg.connect(P, autocommit=True) as p, psycopg.connect(R, autocommit=True) as r:
        d = r.execute("SHOW recovery_min_apply_delay").fetchone()[0]
        for i in range(n):
            id_ = p.execute(
                "INSERT INTO orders(note) VALUES (%s) RETURNING id", (f"t{i}",)
            ).fetchone()[0]
            lsn = p.execute("SELECT pg_current_wal_lsn()").fetchone()[0]
            t0 = time.time()
            deadline = t0 + timeout
            caught_up = False
            while time.time() < deadline:
                ok = r.execute(
                    "SELECT pg_last_wal_replay_lsn() >= %s::pg_lsn", (lsn,)
                ).fetchone()[0]
                if ok:
                    caught_up = True
                    break
                time.sleep(0.01)
            waits.append(time.time() - t0)
            if caught_up:
                assert r.execute("SELECT 1 FROM orders WHERE id=%s", (id_,)).fetchone()
            else:
                fallback += 1  # quá hạn: đọc từ primary
    avg_ms = sum(waits) / len(waits) * 1000
    print(f"[delay={d}] with_lsn: fallback {fallback}/{n} lần; chờ trung bình {avg_ms:.0f} ms")


if __name__ == "__main__":
    naive()
    with_lsn()

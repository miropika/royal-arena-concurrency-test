import os
import time
import secrets
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
from fastapi import FastAPI, Header, HTTPException

app = FastAPI(title="Isolated Synthetic Concurrency Test")
ROOT = Path(__file__).resolve().parents[1]
SETUP_SQL = (ROOT / "tests" / "setup.sql").read_text(encoding="utf-8")
ASSERT_SQL = (ROOT / "tests" / "assert_concurrency.sql").read_text(encoding="utf-8")
USER_ID = "00000000-0000-4000-8000-000000000003"
IDEMPOTENCY_KEY = "00000000-0000-4000-8000-000000000777"

@app.get("/")
def health():
    return {"service": "isolated-synthetic-concurrency-runner", "status": "ready"}

def connect(app_name: str):
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not configured")
    return psycopg.connect(url, application_name=app_name)

def run_one():
    with connect("synthetic-spin") as conn:
        row = conn.execute(
            "select concurrency_test.spin(%s::uuid, 100, %s::uuid)",
            (USER_ID, IDEMPOTENCY_KEY),
        ).fetchone()
        return row[0]

def run_test():
    # This drops/recreates only the synthetic schema in this isolated database.
    with connect("fixture-setup") as conn:
        conn.execute(SETUP_SQL)

    holder = connect("lock-holder")
    holder.execute("begin")
    holder.execute(
        "select balance from concurrency_test.wallets where user_id=%s::uuid for update",
        (USER_ID,),
    )

    try:
        with connect("test-coordinator") as coordinator:
            ready = False
            for _ in range(60):
                count = coordinator.execute(
                    """
                    select count(*) from pg_stat_activity
                    where application_name='lock-holder'
                      and state='idle in transaction'
                      and query like '%for update%'
                    """
                ).fetchone()[0]
                if count:
                    ready = True
                    break
                time.sleep(0.1)
            if not ready:
                raise RuntimeError("Could not confirm the synthetic wallet row lock")

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run_one)
            second = pool.submit(run_one)
            time.sleep(1.5)
            holder.execute("commit")
            result_a = first.result(timeout=20)
            result_b = second.result(timeout=20)
    finally:
        try:
            holder.close()
        except Exception:
            pass

    if result_a != result_b:
        raise RuntimeError("Concurrent requests returned different responses")

    with connect("assertions") as conn:
        conn.execute(ASSERT_SQL)

    return {
        "status": "passed",
        "same_response_for_both_requests": True,
        "one_round_one_spin_one_debit_one_credit": True,
        "expected_final_synthetic_balance": 16800,
        "response": result_a,
        "scope": "synthetic disposable PostgreSQL fixture only; not production settlement code",
    }

@app.post("/run")
def run(token: str | None = Header(default=None, alias="X-Test-Token")):
    expected = os.environ.get("TEST_TOKEN", "")
    if not expected or not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="Unauthorized")
    try:
        return run_test()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Synthetic test failed: {type(exc).__name__}: {exc}")

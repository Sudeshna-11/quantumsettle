"""FastAPI + Jinja2 dashboard for QuantumSettle.

Routes
------
  GET  /                Dashboard — pick a date, see processing status and P&L.
  GET  /perf            Benchmark chart: optimized vs not-optimized timings.
  GET  /health          Liveness probe (no DB).
  GET  /docs            FastAPI's auto-generated Swagger UI.

Launch
------
  python -m quantumsettle.api.run --port 8765
or
  uvicorn quantumsettle.api.main:app --reload
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path
from typing import Any

import oracledb
from fastapi import Depends, FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from quantumsettle.db import connect

BASE      = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE / "templates"))

app = FastAPI(title="QuantumSettle Dashboard")


# ---------------------------------------------------------------------------
# DB dependency + helpers
# ---------------------------------------------------------------------------

def get_db():
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


def _refcursor(conn, plsql_func: str, *args: Any) -> tuple[list[str], list[tuple]]:
    """Invoke a SYS_REFCURSOR-returning PL/SQL function and fetch all rows."""
    cur = conn.cursor()
    rc  = cur.var(oracledb.CURSOR)
    binds = [rc] + list(args)
    placeholders = ", ".join(f":{i}" for i in range(2, len(binds) + 1))
    cur.execute(f"BEGIN :1 := {plsql_func}({placeholders}); END;", binds)
    inner = rc.getvalue()
    cols  = [d[0].lower() for d in inner.description]
    rows  = inner.fetchall()
    inner.close()
    cur.close()
    return cols, rows


def _available_dates(conn) -> list[str]:
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT trade_date FROM trades ORDER BY trade_date DESC")
        return [
            r[0].date().isoformat() if hasattr(r[0], "date") else r[0].isoformat()
            for r in cur.fetchall()
        ]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, d: str | None = None, conn=Depends(get_db)) -> Any:
    available = _available_dates(conn)

    business_date: dt.date | None = None
    if d:
        try:
            business_date = dt.date.fromisoformat(d)
        except ValueError:
            pass
    if business_date is None and available:
        business_date = dt.date.fromisoformat(available[0])

    context: dict[str, Any] = {
        "available_dates": available,
        "business_date":   business_date.isoformat() if business_date else None,
        "trade_total":     0,
        "processed_total": 0,
        "proc_cols": [], "proc_rows": [],
        "pnl_cols":  [], "pnl_rows":  [],
        "recent_batches": [],
    }

    if business_date is not None:
        # processing status (Phase 2 result)
        context["proc_cols"], context["proc_rows"] = _refcursor(
            conn, "pkg_report_optimized.get_processing_status", business_date)

        # daily P&L (Phase 3 result)
        context["pnl_cols"], context["pnl_rows"] = _refcursor(
            conn, "pkg_report_optimized.get_daily_pnl", business_date, None)

        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*),"
                "       SUM(CASE WHEN processed='Y' THEN 1 ELSE 0 END) "
                "  FROM trades WHERE trade_date = :d",
                d=business_date,
            )
            total, processed = cur.fetchone()
            context["trade_total"]     = total or 0
            context["processed_total"] = processed or 0

    # Recent batch audit rows — useful while the page renders, regardless of date.
    with conn.cursor() as cur:
        cur.execute(
            """SELECT batch_id, batch_name, batch_type, status,
                      rows_processed, rows_rejected, elapsed_ms
                 FROM batch_audit
                ORDER BY batch_id DESC
                FETCH FIRST 8 ROWS ONLY"""
        )
        context["recent_batches"] = cur.fetchall()

    return templates.TemplateResponse(request, "dashboard.html", context)


@app.get("/perf", response_class=HTMLResponse)
def perf(request: Request, conn=Depends(get_db)) -> Any:
    with conn.cursor() as cur:
        cur.execute(
            """SELECT operation_name, variant, elapsed_ms, rows_processed,
                      TO_CHAR(captured_at, 'YYYY-MM-DD HH24:MI:SS')
                 FROM perf_metrics
                WHERE elapsed_ms IS NOT NULL
                ORDER BY metric_id DESC"""
        )
        rows = cur.fetchall()

    # Most recent OPTIMIZED / NOT_OPTIMIZED pair per operation_name.
    latest: dict[str, dict[str, dict[str, float]]] = {}
    for op, variant, ms, n_rows, _ts in rows:
        latest.setdefault(op, {})
        if variant not in latest[op]:
            latest[op][variant] = {"elapsed_ms": float(ms or 0),
                                   "rows":       float(n_rows or 0)}

    ops_paired = [op for op, v in latest.items()
                  if "OPTIMIZED" in v and "NOT_OPTIMIZED" in v]
    chart = {
        "labels":        ops_paired,
        "optimized":     [latest[op]["OPTIMIZED"]    ["elapsed_ms"] / 1000.0 for op in ops_paired],
        "not_optimized": [latest[op]["NOT_OPTIMIZED"]["elapsed_ms"] / 1000.0 for op in ops_paired],
        "speedups": [
            round(latest[op]["NOT_OPTIMIZED"]["elapsed_ms"]
                  / latest[op]["OPTIMIZED"]["elapsed_ms"], 2)
            if latest[op]["OPTIMIZED"]["elapsed_ms"] > 0 else None
            for op in ops_paired
        ],
    }
    return templates.TemplateResponse(request, "perf.html", {
        "metrics": rows[:30],
        "chart":   chart,
    })

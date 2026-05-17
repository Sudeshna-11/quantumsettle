"""Three-phase, optimized-vs-not-optimized benchmark harness.

For each phase (Ingest, Process, Report) this runner times both variants on
the same dataset and prints a speedup table. Timings persist in PERF_METRICS.

  python -m quantumsettle.bench.run --trades 5000  --days 5
  python -m quantumsettle.bench.run --trades 20000 --days 5
"""

from __future__ import annotations

import datetime as dt
import sys
import time
from pathlib import Path

import click
import oracledb
from rich.console import Console
from rich.table import Table

from quantumsettle.config import PROJECT_ROOT
from quantumsettle.db import connect
from quantumsettle.faker.generators import (
    STAGED_DIR, TRADE_HEADER, GenContext, iter_trades, write_csv,
)
from quantumsettle.faker.run import _load_ref_data
from quantumsettle.faker.seed import seed_all

console = Console()

VARIANT_LABELS = ("OPTIMIZED", "NOT_OPTIMIZED")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _reset_state(conn: oracledb.Connection) -> None:
    """Truncate trades + ingest_errors and rebuild the MV log."""
    with conn.cursor() as cur:
        cur.callproc("pkg_perf.reset_for_bench")
    conn.commit()


def _regenerate_csv(trades: int, days: int) -> tuple[Path, list[dt.date]]:
    """Always end on a fixed Friday so benchmark numbers are reproducible."""
    end = dt.date(2026, 5, 15)   # Friday
    weekdays: list[dt.date] = []
    d = end
    while len(weekdays) < days:
        if d.weekday() < 5:
            weekdays.append(d)
        d -= dt.timedelta(days=1)
    weekdays.reverse()
    start, last = weekdays[0], weekdays[-1]
    per_day = max(trades // days, 1)

    # Wipe any older CSVs so the external table doesn't pick up the wrong file.
    for p in STAGED_DIR.glob("*.csv"):
        p.unlink()

    ctx = _load_ref_data()
    trades_path = STAGED_DIR / f"bench_trades_{start:%Y%m%d}_{last:%Y%m%d}.csv"
    n = write_csv(trades_path, TRADE_HEADER,
                  iter_trades(ctx, start, last, per_day))
    console.print(f"  generated {n:,} trades into {trades_path.name}")
    return trades_path, weekdays


def _time_ingest(conn: oracledb.Connection, variant: str, filename: str) -> float:
    package = "pkg_ingest_optimized" if variant == "OPTIMIZED" else "pkg_ingest_not_optimized"
    with conn.cursor() as cur:
        m_var = cur.var(int); ret = cur.var(int)
        cur.execute("BEGIN :m := pkg_perf.start_run(:op, :v); END;",
                    m=m_var, op="INGEST", v=variant)
        m_id = int(m_var.getvalue())
        t0 = time.perf_counter()
        if variant == "OPTIMIZED":
            cur.execute(f"BEGIN :r := {package}.load_trades(:f, :c); END;",
                        r=ret, f=filename, c=5000)
        else:
            cur.execute(f"BEGIN :r := {package}.load_trades(:f); END;",
                        r=ret, f=filename)
        elapsed = time.perf_counter() - t0
        conn.commit()
        cur.execute("SELECT COUNT(*) FROM trades"); n_rows = cur.fetchone()[0]
        cur.execute("BEGIN pkg_perf.end_run(:m, :n); END;", m=m_id, n=n_rows)
    console.print(f"    INGEST       [{variant:<14}]  {elapsed:6.2f}s   rows={n_rows:,}")
    return elapsed


def _time_process(conn: oracledb.Connection, variant: str) -> float:
    package = "pkg_process_optimized" if variant == "OPTIMIZED" else "pkg_process_not_optimized"
    with conn.cursor() as cur:
        m_var = cur.var(int)
        cur.execute("BEGIN :m := pkg_perf.start_run(:op, :v); END;",
                    m=m_var, op="PROCESS", v=variant)
        m_id = int(m_var.getvalue())
        t0 = time.perf_counter()
        cur.callproc(f"{package}.run_all_pending")
        elapsed = time.perf_counter() - t0
        conn.commit()
        cur.execute("SELECT COUNT(*) FROM trades WHERE processed = 'Y'")
        n_rows = cur.fetchone()[0]
        cur.execute("BEGIN pkg_perf.end_run(:m, :n); END;", m=m_id, n=n_rows)
    console.print(f"    PROCESS      [{variant:<14}]  {elapsed:6.2f}s   rows={n_rows:,}")
    return elapsed


def _time_report(conn: oracledb.Connection, variant: str,
                 weekdays: list[dt.date]) -> float:
    package = "pkg_report_optimized" if variant == "OPTIMIZED" else "pkg_report_not_optimized"
    with conn.cursor() as cur:
        m_var = cur.var(int)
        cur.execute("BEGIN :m := pkg_perf.start_run(:op, :v); END;",
                    m=m_var, op="REPORT", v=variant)
        m_id = int(m_var.getvalue())

        t0 = time.perf_counter()
        # Run the report once per loaded trade_date to amortise per-call overhead.
        rows_total = 0
        for d in weekdays:
            rc = cur.var(oracledb.CURSOR)
            cur.execute(
                f"BEGIN :1 := {package}.get_daily_pnl(:2, :3); END;",
                [rc, d, None],
            )
            inner = rc.getvalue()
            rows_total += len(inner.fetchall())
            inner.close()
        elapsed = time.perf_counter() - t0

        cur.execute("BEGIN pkg_perf.end_run(:m, :n); END;",
                    m=m_id, n=rows_total)
        conn.commit()
    console.print(f"    REPORT       [{variant:<14}]  {elapsed:6.2f}s   "
                  f"rows={rows_total:,} across {len(weekdays)} dates")
    return elapsed


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@click.command()
@click.option("--trades", default=5000, show_default=True, type=int,
              help="Total trades to generate.")
@click.option("--days", default=5, show_default=True, type=int,
              help="Number of business days to spread the trades over.")
def main(trades: int, days: int) -> None:
    console.rule("[bold]QuantumSettle benchmark — optimized vs. not optimized[/bold]")
    console.print(f"Volume: [cyan]{trades:,}[/cyan] trades over "
                  f"[cyan]{days}[/cyan] business days\n")

    # Seed reference data once. Idempotent.
    seed_all()
    trades_csv, weekdays = _regenerate_csv(trades, days)

    results: dict[tuple[str, str], float] = {}

    with connect() as conn:
        for variant in VARIANT_LABELS:
            console.rule(f"[bold cyan]{variant.replace('_', ' ').title()}[/bold cyan]")
            _reset_state(conn)
            results[("INGEST",  variant)] = _time_ingest (conn, variant, trades_csv.name)
            results[("PROCESS", variant)] = _time_process(conn, variant)
            results[("REPORT",  variant)] = _time_report (conn, variant, weekdays)

    # --- summary -----------------------------------------------------------
    console.rule("[bold green]Results[/bold green]")
    t = Table(header_style="bold")
    t.add_column("Phase")
    t.add_column("Optimized (s)",     justify="right")
    t.add_column("Not optimized (s)", justify="right")
    t.add_column("Speedup",           justify="right")
    for phase in ("INGEST", "PROCESS", "REPORT"):
        o = results[(phase, "OPTIMIZED")]
        n = results[(phase, "NOT_OPTIMIZED")]
        speedup = (n / o) if o > 0 else float("inf")
        t.add_row(phase, f"{o:7.2f}", f"{n:7.2f}", f"{speedup:5.1f}×")
    total_o = sum(results[(p, "OPTIMIZED")]     for p in ("INGEST","PROCESS","REPORT"))
    total_n = sum(results[(p, "NOT_OPTIMIZED")] for p in ("INGEST","PROCESS","REPORT"))
    total_speedup = (total_n / total_o) if total_o > 0 else float("inf")
    t.add_row("[bold]TOTAL[/bold]",
              f"[bold]{total_o:7.2f}[/bold]",
              f"[bold]{total_n:7.2f}[/bold]",
              f"[bold]{total_speedup:5.1f}×[/bold]")
    console.print(t)
    console.print("\nFull per-step metrics:  "
                  "SELECT * FROM perf_metrics ORDER BY metric_id DESC;")


if __name__ == "__main__":
    main()

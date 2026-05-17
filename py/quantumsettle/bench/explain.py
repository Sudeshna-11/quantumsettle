"""Generate the side-by-side EXPLAIN PLAN comparison for the perf story.

For each probe, runs EXPLAIN PLAN against an "optimized" SQL and a "not
optimized" equivalent, capturing both plans via PKG_PERF.explain_plan. Writes
a markdown report to docs/perf-story.md.

The probes show query SHAPE, not row counts — partition pruning, MV query
rewrite, and index access patterns that the bench numbers from run.py only
hint at.

  python -m quantumsettle.bench.explain
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import oracledb
from rich.console import Console

from quantumsettle.config import PROJECT_ROOT
from quantumsettle.db import connect

console = Console()

REPORT_PATH = PROJECT_ROOT / "docs" / "perf-story.md"
TEST_DATE   = date(2026, 5, 12)
TEST_TID    = 12345


@dataclass
class Probe:
    name: str
    summary: str
    why: str
    optimized: str
    not_optimized: str
    look_for: str


PROBES: list[Probe] = [
    Probe(
        name="Process UPDATE — partition pruning (Phase 2)",
        summary=(
            "Updating every unprocessed trade for one trade_date. The "
            "optimized version touches one partition; the not-optimized "
            "version scans every partition."
        ),
        why=(
            "This is the headline win in the project. Both queries achieve "
            "the same result — set processed='Y', derive settlement_date and "
            "net_amount — but only the optimized one keeps trade_date in the "
            "WHERE clause. Because trade_date is the table's partition key, "
            "the planner prunes to a SINGLE partition. The not-optimized "
            "version locates each trade by trade_id alone and has to scan "
            "every partition."
        ),
        optimized=f"""
            UPDATE trades
               SET processed = 'Y',
                   net_amount = CASE side
                                    WHEN 'BUY' THEN gross_amount + commission
                                    ELSE             gross_amount - commission
                                END,
                   updated_at = SYSTIMESTAMP
             WHERE trade_date = DATE '{TEST_DATE}'
               AND processed  = 'N'
        """,
        not_optimized=f"""
            UPDATE trades
               SET processed = 'Y',
                   net_amount = CASE side
                                    WHEN 'BUY' THEN gross_amount + commission
                                    ELSE             gross_amount - commission
                                END,
                   updated_at = SYSTIMESTAMP
             WHERE trade_id = {TEST_TID}
        """,
        look_for=(
            "The `Pstart` / `Pstop` columns. Optimized: a single partition "
            "number (PARTITION RANGE SINGLE). Not optimized: `1` to `KEY` or "
            "`FINAL` (PARTITION RANGE ALL) — every partition is opened. With "
            "a row-by-row cursor loop, that cost is paid PER TRADE."
        ),
    ),
    Probe(
        name="Trade lookup by external reference (Phase 1)",
        summary=(
            "Finding one trade by its source-system reference. Used for "
            "idempotency checks during ingest."
        ),
        why=(
            "The unique constraint on (source_system, external_trade_ref) is "
            "GLOBAL — not LOCAL — precisely so a single-row lookup does not "
            "have to scan every partition. The plan shows INDEX UNIQUE SCAN, "
            "which is O(log n)."
        ),
        optimized="""
            SELECT trade_id, trade_date, processed
              FROM trades
             WHERE source_system      = 'FRONT_OMS'
               AND external_trade_ref = 'EXT-20260512-000001234'
        """,
        not_optimized="""
            SELECT trade_id, trade_date, processed
              FROM trades
             WHERE external_trade_ref = 'EXT-20260512-000001234'
        """,
        look_for=(
            "Optimized: INDEX UNIQUE SCAN on UK_TRADES_SOURCE_REF — one index "
            "probe. Not optimized (missing source_system so the unique index "
            "is unusable): a much wider scan with PARTITION RANGE ALL."
        ),
    ),
    Probe(
        name="Daily P&L aggregation — MV query rewrite (Phase 3)",
        summary=(
            "Aggregating trades into daily P&L per (account, currency). "
            "Optimized version reads the pre-aggregated MV; not optimized "
            "re-aggregates the base table."
        ),
        why=(
            "MV_DAILY_PNL keeps the aggregation permanently up to date "
            "(REFRESH FAST ON COMMIT). The optimized query just reads a "
            "handful of pre-summarised rows. The not-optimized query does the "
            "full GROUP BY against the partition every time — and the "
            "NO_REWRITE hint stops the planner from quietly substituting the "
            "MV behind the scenes, so the cost is real."
        ),
        optimized=f"""
            SELECT trade_date, account_id, currency,
                   SUM(trade_count) AS trades, SUM(sum_net_amount) AS net
              FROM mv_daily_pnl
             WHERE trade_date = DATE '{TEST_DATE}'
             GROUP BY trade_date, account_id, currency
        """,
        not_optimized=f"""
            SELECT /*+ NO_REWRITE */
                   trade_date, account_id, currency,
                   COUNT(*) AS trades, SUM(net_amount) AS net
              FROM trades
             WHERE trade_date = DATE '{TEST_DATE}'
             GROUP BY trade_date, account_id, currency
        """,
        look_for=(
            "Optimized: a small full scan of MV_DAILY_PNL (already aggregated, "
            "so very few rows). Not optimized: PARTITION RANGE SINGLE on TRADES "
            "plus a HASH GROUP BY — fast on small data, expensive on large data "
            "and on every single call."
        ),
    ),
]


def _capture(conn: oracledb.Connection, sql: str) -> str:
    with conn.cursor() as cur:
        clob_var = cur.var(oracledb.CLOB)
        cur.execute("BEGIN :ret := pkg_perf.explain_plan(:sql); END;",
                    ret=clob_var, sql=sql.strip())
        plan = clob_var.getvalue()
        return plan.read() if hasattr(plan, "read") else str(plan)


def _write_report(blocks: list[tuple[Probe, str, str]]) -> None:
    lines: list[str] = []
    lines += [
        "# Performance story — EXPLAIN PLAN side by side",
        "",
        "> Generated by `python -m quantumsettle.bench.explain`. Re-run any time",
        "> to refresh against the current schema.",
        "",
        "The benchmark numbers in the README tell you *how much* faster the",
        "optimized version is. The plans below tell you *why* — partition",
        "pruning, global vs. local index choice, and materialized-view query",
        "rewrite.",
        "",
        "## What to read first",
        "",
        "Each probe below has two plans. When comparing them, watch:",
        "",
        "- **`Operation`** — `PARTITION RANGE SINGLE` means Oracle pruned to",
        "  one partition. `PARTITION RANGE ALL` means it had to open every one.",
        "- **`Pstart` / `Pstop`** — the partition ID range actually visited.",
        "- **`Name`** — which index or MV was used.",
        "- **`Cost`** — the optimizer's estimate; lower is better, but it is",
        "  an *estimate*. Wall-clock numbers in `perf_metrics` are ground truth.",
        "",
    ]
    for probe, plan_opt, plan_not in blocks:
        lines += [
            f"## {probe.name}",
            "",
            f"**What's happening:** {probe.summary}",
            "",
            f"**Why it matters:** {probe.why}",
            "",
            "### Optimized version",
            "",
            "```sql",
            probe.optimized.strip(),
            "```",
            "",
            "```",
            plan_opt.strip(),
            "```",
            "",
            "### Not optimized version",
            "",
            "```sql",
            probe.not_optimized.strip(),
            "```",
            "",
            "```",
            plan_not.strip(),
            "```",
            "",
            "**What to look for:**",
            "",
            probe.look_for,
            "",
            "---",
            "",
        ]
    lines += [
        "## A note on AUTOTRACE-style runtime stats",
        "",
        "Full AUTOTRACE (logical reads, physical reads, sorts, etc.) requires",
        "SELECT on V$SQL_PLAN_STATISTICS_ALL and V$SQL, which only SYS can grant.",
        "In container setups where you connect as SYSTEM, those grants fail.",
        "The wall-clock numbers in `perf_metrics` are the practical alternative —",
        "captured via DBMS_UTILITY.GET_TIME by `PKG_PERF.start_run` / `end_run`.",
    ]

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")
    console.print(f"[green]Wrote[/green] {REPORT_PATH.relative_to(PROJECT_ROOT)}")


def main() -> int:
    blocks: list[tuple[Probe, str, str]] = []
    with connect() as conn:
        for probe in PROBES:
            console.print(f"  capturing plan for [cyan]{probe.name}[/cyan] ...")
            plan_opt = _capture(conn, probe.optimized)
            plan_not = _capture(conn, probe.not_optimized)
            blocks.append((probe, plan_opt, plan_not))
    _write_report(blocks)
    return 0


if __name__ == "__main__":
    sys.exit(main())

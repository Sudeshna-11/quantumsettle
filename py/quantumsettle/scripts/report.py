"""Drive the Report phase from Python.

  python -m quantumsettle.scripts.report pnl     --variant optimized      --date 2026-05-08
  python -m quantumsettle.scripts.report pnl     --variant not-optimized  --date 2026-05-08
  python -m quantumsettle.scripts.report refresh
"""

from __future__ import annotations

import datetime as dt
from typing import Any

import click
import oracledb
from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect

console = Console()


PACKAGES = {
    "optimized":     "pkg_report_optimized",
    "not-optimized": "pkg_report_not_optimized",
}


def _fetch_refcursor(package: str, func: str, args: list[Any]) -> tuple[list[str], list[tuple]]:
    """Invoke <package>.<func>(args...) and materialise the returned cursor."""
    with connect() as conn, conn.cursor() as cur:
        rc    = cur.var(oracledb.CURSOR)
        binds = [rc] + args
        placeholders = ", ".join(f":{i}" for i in range(2, len(binds) + 1))
        cur.execute(
            f"BEGIN :1 := {package}.{func}({placeholders}); END;",
            binds,
        )
        inner = rc.getvalue()
        cols  = [d[0].lower() for d in inner.description]
        rows  = inner.fetchall()
        inner.close()
    return cols, rows


def _print_table(title: str, cols: list[str], rows: list[tuple]) -> None:
    t = Table(title=title, header_style="bold")
    for c in cols:
        t.add_column(c)
    for r in rows:
        t.add_row(*(
            f"{x:,.2f}" if isinstance(x, float)
            else f"{x:,}"  if isinstance(x, int)
            else str(x)    if x is not None
            else "—"
            for x in r
        ))
    console.print(t)


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--variant",
              type=click.Choice(["optimized", "not-optimized"]),
              default="optimized", show_default=True)
@click.option("--date", "business_date", required=True, help="YYYY-MM-DD")
@click.option("--account-id", type=int, default=None,
              help="Optional account filter (defaults to all).")
def pnl(variant: str, business_date: str, account_id: int | None) -> None:
    """Daily P&L per account/currency for one trade date."""
    package = PACKAGES[variant]
    d = dt.date.fromisoformat(business_date)
    cols, rows = _fetch_refcursor(package, "get_daily_pnl", [d, account_id])
    _print_table(f"Daily P&L — {d}  ({variant})", cols, rows)


@cli.command()
@click.option("--date", "business_date", required=True, help="YYYY-MM-DD")
def status(business_date: str) -> None:
    """Processed vs unprocessed counts from PKG_REPORT_OPTIMIZED."""
    d = dt.date.fromisoformat(business_date)
    cols, rows = _fetch_refcursor("pkg_report_optimized",
                                  "get_processing_status", [d])
    _print_table(f"Processing status — {d}", cols, rows)


@cli.command()
def refresh() -> None:
    """Force a refresh of MV_DAILY_PNL (it is fast-refresh-on-commit anyway)."""
    with connect() as conn, conn.cursor() as cur:
        cur.callproc("pkg_report_optimized.refresh")
        conn.commit()
    console.print("[green]MV_DAILY_PNL refreshed.[/green]")


if __name__ == "__main__":
    cli()

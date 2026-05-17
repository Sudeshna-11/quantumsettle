"""Drive the Process phase from Python.

  python -m quantumsettle.scripts.process run     --variant optimized      --date 2026-05-08
  python -m quantumsettle.scripts.process run     --variant not-optimized  --date 2026-05-08
  python -m quantumsettle.scripts.process run-all --variant optimized
  python -m quantumsettle.scripts.process status  --date 2026-05-08
"""

from __future__ import annotations

import datetime as dt

import click
from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect

console = Console()


PACKAGES = {
    "optimized":     "pkg_process_optimized",
    "not-optimized": "pkg_process_not_optimized",
}


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--variant",
              type=click.Choice(["optimized", "not-optimized"]),
              default="optimized", show_default=True)
@click.option("--date", "trade_date", required=True,
              help="Trade date (YYYY-MM-DD) to process.")
def run(variant: str, trade_date: str) -> None:
    """Process one trade_date (derive net_amount, settlement_date, flip processed)."""
    package = PACKAGES[variant]
    d = dt.date.fromisoformat(trade_date)
    with connect() as conn, conn.cursor() as cur:
        batch_id_var = cur.var(int)
        cur.execute(f"BEGIN :ret := {package}.run(:d); END;",
                    ret=batch_id_var, d=d)
        conn.commit()
        bid = int(batch_id_var.getvalue())
    console.print(f"[green]{package}.run({d}) ok[/green]  batch_id={bid}")
    _show_status(d)


@cli.command(name="run-all")
@click.option("--variant",
              type=click.Choice(["optimized", "not-optimized"]),
              default="optimized", show_default=True)
def run_all(variant: str) -> None:
    """Process every trade_date that still has unprocessed trades."""
    package = PACKAGES[variant]
    with connect() as conn, conn.cursor() as cur:
        cur.callproc(f"{package}.run_all_pending")
        conn.commit()
    console.print(f"[green]{package}.run_all_pending ok[/green]")
    _show_status(None)


@cli.command()
@click.option("--date", "trade_date", default=None,
              help="Optional YYYY-MM-DD; omit to show all dates.")
def status(trade_date: str | None) -> None:
    """Show processed vs unprocessed trade counts."""
    d = dt.date.fromisoformat(trade_date) if trade_date else None
    _show_status(d)


def _show_status(d: dt.date | None) -> None:
    with connect() as conn, conn.cursor() as cur:
        if d is None:
            cur.execute(
                """
                SELECT trade_date, processed, COUNT(*)
                  FROM trades
                 GROUP BY trade_date, processed
                 ORDER BY trade_date, processed
                """
            )
            rows = cur.fetchall()
            title = "Processing status (all dates)"
        else:
            cur.execute(
                """
                SELECT trade_date, processed, COUNT(*)
                  FROM trades
                 WHERE trade_date = :d
                 GROUP BY trade_date, processed
                 ORDER BY processed
                """,
                d=d,
            )
            rows = cur.fetchall()
            title = f"Processing status ({d})"

    t = Table(title=title, header_style="bold")
    for h in ("trade_date", "processed", "count"):
        t.add_column(h)
    for r in rows:
        t.add_row(str(r[0]), r[1], f"{r[2]:,}")
    console.print(t)


if __name__ == "__main__":
    cli()

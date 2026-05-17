"""Drive the Ingest phase from Python.

  python -m quantumsettle.scripts.ingest load --variant optimized      <csv>
  python -m quantumsettle.scripts.ingest load --variant not-optimized  <csv>
  python -m quantumsettle.scripts.ingest report
"""

from __future__ import annotations

import sys

import click
from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect

console = Console()


PACKAGES = {
    "optimized":     "pkg_ingest_optimized",
    "not-optimized": "pkg_ingest_not_optimized",
}


def _call_load(package: str, filename: str, chunk_size: int | None) -> int:
    """Invoke <package>.load_trades(<file>[, <chunk>]) and return the batch_id."""
    with connect() as conn, conn.cursor() as cur:
        batch_id_var = cur.var(int)
        if package == "pkg_ingest_optimized":
            cur.execute(
                f"BEGIN :ret := {package}.load_trades(:fn, :chunk); END;",
                ret=batch_id_var, fn=filename,
                chunk=chunk_size if chunk_size is not None else 5000,
            )
        else:
            # Not-optimized package has no chunk_size — it's row-by-row by design.
            cur.execute(
                f"BEGIN :ret := {package}.load_trades(:fn); END;",
                ret=batch_id_var, fn=filename,
            )
        conn.commit()
        return int(batch_id_var.getvalue())


def _show_batch(batch_id: int) -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT batch_name, batch_type, status, rows_processed,
                   rows_rejected, elapsed_ms, error_summary
              FROM batch_audit WHERE batch_id = :id
            """,
            id=batch_id,
        )
        row = cur.fetchone()
    if not row:
        console.print(f"[red]No batch_audit row for id={batch_id}[/red]")
        return
    t = Table(title=f"Batch {batch_id}", header_style="bold green")
    t.add_column("Field"); t.add_column("Value")
    t.add_row("Name",          row[0])
    t.add_row("Type",          row[1])
    t.add_row("Status",        row[2])
    t.add_row("Rows OK",       f"{(row[3] or 0):,}")
    t.add_row("Rows rejected", f"{(row[4] or 0):,}")
    t.add_row("Elapsed (ms)",  f"{(row[5] or 0):,.0f}")
    if row[6]:
        t.add_row("Error", row[6])
    console.print(t)


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.argument("filename")
@click.option("--variant",
              type=click.Choice(["optimized", "not-optimized"]),
              default="optimized", show_default=True,
              help="Which ingest package to call.")
@click.option("--chunk-size", default=5000, show_default=True, type=int,
              help="Rows per FORALL chunk (optimized only — ignored otherwise).")
def load(filename: str, variant: str, chunk_size: int) -> None:
    """Ingest trades from data/staged/<FILENAME>."""
    package = PACKAGES[variant]
    console.print(f"[bold]Ingest[/bold] via [cyan]{package}[/cyan]: {filename}")
    batch_id = _call_load(package, filename, chunk_size)
    _show_batch(batch_id)


@cli.command()
def report() -> None:
    """Show current trades count and recent batches."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM trades")
        t_count = cur.fetchone()[0]
        cur.execute(
            "SELECT COUNT(*) FROM trades WHERE processed = 'Y'"
        )
        proc_count = cur.fetchone()[0]
        cur.execute(
            """
            SELECT batch_id, batch_name, batch_type, status,
                   rows_processed, rows_rejected, elapsed_ms
              FROM batch_audit
             ORDER BY batch_id DESC
             FETCH FIRST 10 ROWS ONLY
            """
        )
        batches = cur.fetchall()

    console.print(
        f"[bold]Trades:[/bold] {t_count:,}    "
        f"[bold]Processed:[/bold] {proc_count:,} "
        f"({(100*proc_count/t_count if t_count else 0):.0f}%)\n"
    )

    if batches:
        bt = Table(title="Recent batches", header_style="bold")
        for h in ("ID", "Name", "Type", "Status", "OK", "Rej", "ms"):
            bt.add_column(h)
        for b in batches:
            bt.add_row(str(b[0]), b[1], b[2], b[3],
                       f"{b[4] or 0:,}", f"{b[5] or 0:,}",
                       f"{b[6] or 0:,.0f}")
        console.print(bt)


if __name__ == "__main__":
    cli()

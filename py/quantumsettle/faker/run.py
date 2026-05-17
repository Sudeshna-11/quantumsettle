"""CLI entry point for the data faker.

  python -m quantumsettle.faker.run seed
  python -m quantumsettle.faker.run generate --days 5 --trades-per-day 1000
  python -m quantumsettle.faker.run all      --days 5 --trades-per-day 1000
"""

from __future__ import annotations

import random
from datetime import date, timedelta
from typing import Any

import click
from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect
from quantumsettle.faker.generators import (
    STAGED_DIR,
    TRADE_HEADER,
    GenContext,
    iter_trades,
    write_csv,
)
from quantumsettle.faker.seed import seed_all

console = Console()


def _load_ref_data() -> GenContext:
    """Read the seeded reference rows back out so the trade generator can
    reference real surrogate keys."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT instrument_id, symbol, isin, currency, primary_mic FROM instruments"
        )
        instruments = [
            {"instrument_id": r[0], "symbol": r[1], "isin": r[2],
             "currency":      r[3], "primary_mic": r[4]}
            for r in cur.fetchall()
        ]

        cur.execute(
            "SELECT counterparty_id, short_name FROM counterparties "
            "WHERE counterparty_type = 'BROKER'"
        )
        brokers = [{"counterparty_id": r[0], "name": r[1]} for r in cur.fetchall()]

        cur.execute(
            "SELECT account_id, account_code FROM accounts WHERE active_flag = 'Y'"
        )
        accounts = [{"account_id": r[0], "account_code": r[1]} for r in cur.fetchall()]

    if not (instruments and brokers and accounts):
        raise RuntimeError("Reference data is empty. Run 'seed' first.")

    return GenContext(
        rng=random.Random(42),
        instruments=instruments,
        brokers=brokers,
        accounts=accounts,
    )


@click.group()
def cli() -> None:
    pass


@cli.command()
def seed() -> None:
    """Load instruments, brokers and accounts."""
    seed_all()


@cli.command()
@click.option("--days", default=5, show_default=True, type=int,
              help="How many trading days to generate (weekdays only).")
@click.option("--trades-per-day", default=1000, show_default=True, type=int)
@click.option("--end-date", default=None,
              help="Last trade_date (YYYY-MM-DD). Default: today.")
def generate(days: int, trades_per_day: int, end_date: str | None) -> None:
    """Generate a trades CSV into data/staged/."""
    ctx  = _load_ref_data()
    last = date.fromisoformat(end_date) if end_date else date.today()

    # Walk backwards collecting `days` weekdays.
    weekdays: list[date] = []
    d = last
    while len(weekdays) < days:
        if d.weekday() < 5:
            weekdays.append(d)
        d -= timedelta(days=1)
    weekdays.reverse()
    start, end = weekdays[0], weekdays[-1]
    console.print(f"Generating trades for [cyan]{start}[/cyan] .. [cyan]{end}[/cyan]")

    STAGED_DIR.mkdir(parents=True, exist_ok=True)
    trades_path = STAGED_DIR / f"trades_{start:%Y%m%d}_{end:%Y%m%d}.csv"
    n_trades = write_csv(trades_path, TRADE_HEADER,
                         iter_trades(ctx, start, end, trades_per_day))

    summary = Table(title="Generation summary", header_style="bold green")
    summary.add_column("File"); summary.add_column("Rows", justify="right")
    summary.add_row(str(trades_path.relative_to(STAGED_DIR.parent.parent)),
                    f"{n_trades:,}")
    console.print(summary)


@cli.command(name="all")
@click.option("--days", default=5, show_default=True, type=int)
@click.option("--trades-per-day", default=1000, show_default=True, type=int)
@click.pass_context
def all_cmd(ctx: click.Context, days: int, trades_per_day: int) -> None:
    """Seed and generate in one go."""
    ctx.invoke(seed)
    ctx.invoke(generate, days=days, trades_per_day=trades_per_day, end_date=None)


if __name__ == "__main__":
    cli()

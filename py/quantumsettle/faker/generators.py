"""Trade generator.

Outputs CSV files into data/staged/. The Ingest phase reads those CSVs through
the EXT_TRADES external table.

Design notes:
- Trades concentrate around market open/close (a U-shaped intraday curve).
- Quantity is lognormal — most trades are 100–2000 shares, a few are 50k+.
- Prices wobble within the ticker's static price band.

The CSV does NOT include settlement_date or net_amount. Those are DERIVED by
the Process phase, not supplied by the feed.
"""

from __future__ import annotations

import csv
import math
import random
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from rich.console import Console

from quantumsettle.config import PROJECT_ROOT
from quantumsettle.faker.reference_data import TICKERS

console = Console()

STAGED_DIR = PROJECT_ROOT / "data" / "staged"


@dataclass
class GenContext:
    rng: random.Random
    instruments: list[dict[str, Any]]   # rows from instruments table
    brokers:     list[dict[str, Any]]   # rows from counterparties (type=BROKER)
    accounts:    list[dict[str, Any]]   # rows from accounts


def _is_weekday(d: date) -> bool:
    return d.weekday() < 5


def _intraday_seconds(rng: random.Random) -> int:
    """Seconds since 09:30 with a U-shaped distribution (open/close heavy)."""
    market_minutes = 6.5 * 60   # 09:30 to 16:00
    bucket = rng.random()
    if bucket < 0.35:
        minute = rng.uniform(0, 30)                                  # 09:30 – 10:00
    elif bucket < 0.65:
        minute = rng.uniform(market_minutes - 45, market_minutes)    # 15:15 – 16:00
    else:
        minute = rng.uniform(30, market_minutes - 45)                # middle of the day
    return int(minute * 60)


def _lognormal_quantity(rng: random.Random) -> int:
    qty = int(math.exp(rng.gauss(mu=6.2, sigma=1.0)))
    return max(qty, 1)


def iter_trades(
    ctx: GenContext,
    start_date: date,
    end_date: date,
    trades_per_day: int,
    starting_trade_id: int = 1,
) -> Iterator[dict[str, Any]]:
    """Yield trade dicts whose keys match TRADE_HEADER exactly."""
    trade_id = starting_trade_id
    sym_to_inst = {
        t.symbol: i
        for t in TICKERS
        for i in ctx.instruments
        if i["symbol"] == t.symbol
    }
    ticker_pool = [t for t in TICKERS if t.symbol in sym_to_inst]

    d = start_date
    while d <= end_date:
        if not _is_weekday(d):
            d += timedelta(days=1)
            continue
        market_open = datetime.combine(d, datetime.min.time()).replace(hour=9, minute=30)

        for _ in range(trades_per_day):
            ticker  = ctx.rng.choice(ticker_pool)
            instr   = sym_to_inst[ticker.symbol]
            broker  = ctx.rng.choice(ctx.brokers)
            account = ctx.rng.choice(ctx.accounts)
            side    = ctx.rng.choice(("BUY", "SELL"))

            price       = round(ctx.rng.uniform(ticker.price_low, ticker.price_high), 2)
            quantity    = _lognormal_quantity(ctx.rng)
            gross       = round(price * quantity, 2)
            commission  = round(gross * 0.0005, 4)
            executed_at = market_open + timedelta(seconds=_intraday_seconds(ctx.rng))

            yield {
                "trade_id":           trade_id,
                "external_trade_ref": f"EXT-{d:%Y%m%d}-{trade_id:09d}",
                "source_system":      ctx.rng.choice(("FRONT_OMS", "ALGO_BOX", "VOICE_DESK")),
                "trade_date":         d.isoformat(),
                "instrument_id":      instr["instrument_id"],
                "counterparty_id":    broker["counterparty_id"],
                "account_id":         account["account_id"],
                "side":               side,
                "quantity":           quantity,
                "price":              price,
                "currency":           instr["currency"],
                "gross_amount":       gross,
                "commission":         commission,
                "venue_mic":          instr["primary_mic"],
                "executed_at":        executed_at.isoformat(sep=" ", timespec="seconds"),
            }
            trade_id += 1
        d += timedelta(days=1)


# ----------------------------------------------------------------------------
# CSV writer
# ----------------------------------------------------------------------------

# Header order must match the column list in db/01_schema/04_external.sql.
TRADE_HEADER: tuple[str, ...] = (
    "trade_id", "external_trade_ref", "source_system", "trade_date",
    "instrument_id", "counterparty_id", "account_id", "side",
    "quantity", "price", "currency", "gross_amount", "commission",
    "venue_mic", "executed_at",
)


def write_csv(path: Path, header: tuple[str, ...], rows: Iterator[dict[str, Any]]) -> int:
    """Write LF-only CSV. Oracle external tables on Linux expect '\\n'."""
    path.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        for row in rows:
            w.writerow(row)
            n += 1
    return n

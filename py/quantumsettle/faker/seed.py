"""Load reference data — instruments, brokers, accounts — into Oracle.

Idempotent via MERGE so re-running is safe.
"""

from __future__ import annotations

import random
import string

from rich.console import Console

from quantumsettle.db import connect
from quantumsettle.faker.reference_data import (
    BOOKS,
    BROKERS,
    DESKS,
    TICKERS,
    Ticker,
)

console = Console()


# Format-correct (not real) identifiers.
def _synthetic_cusip(rng: random.Random) -> str:
    alphabet = string.digits + string.ascii_uppercase
    return "".join(rng.choices(alphabet, k=9))


def _synthetic_isin(rng: random.Random, country: str = "US") -> str:
    alphabet = string.digits + string.ascii_uppercase
    body = "".join(rng.choices(alphabet, k=9))
    check = rng.choice(string.digits)
    return f"{country}{body}{check}"


def _synthetic_figi(rng: random.Random) -> str:
    alphabet = string.digits + string.ascii_uppercase
    return "BBG" + "".join(rng.choices(alphabet, k=8)) + rng.choice(string.digits)


def _synthetic_lei(rng: random.Random) -> str:
    alphabet = string.digits + string.ascii_uppercase
    return "".join(rng.choices(alphabet, k=18)) + "".join(rng.choices(string.digits, k=2))


def _load_instruments(cur, rng: random.Random) -> int:
    rows = []
    for t in TICKERS:
        rows.append({
            "symbol":          t.symbol,
            "cusip":           _synthetic_cusip(rng),
            "isin":            _synthetic_isin(rng),
            "figi":            _synthetic_figi(rng),
            "primary_mic":     t.primary_mic,
            "instrument_type": "ETF" if t.sector == "ETF" else "EQUITY",
            "currency":        t.currency,
            "country_iso2":    "US",
            "lot_size":        1,
            "tick_size":       0.01,
        })
    cur.executemany(
        """
        MERGE INTO instruments tgt
        USING (
            SELECT :symbol AS symbol, :cusip AS cusip, :isin AS isin, :figi AS figi,
                   :primary_mic AS primary_mic, :instrument_type AS instrument_type,
                   :currency AS currency, :country_iso2 AS country_iso2,
                   :lot_size AS lot_size, :tick_size AS tick_size
              FROM dual
        ) src
        ON (tgt.symbol = src.symbol)
        WHEN NOT MATCHED THEN
            INSERT (instrument_id, symbol, cusip, isin, figi, primary_mic,
                    instrument_type, currency, country_iso2, lot_size, tick_size)
            VALUES (seq_instrument_id.NEXTVAL, src.symbol, src.cusip, src.isin, src.figi,
                    src.primary_mic, src.instrument_type, src.currency, src.country_iso2,
                    src.lot_size, src.tick_size)
        """,
        rows,
    )
    return len(rows)


def _load_brokers(cur, rng: random.Random) -> int:
    rows = [
        (name, name + " (Broker-Dealer)", "BROKER", "US", _synthetic_lei(rng))
        for name in BROKERS
    ]
    cur.executemany(
        """
        MERGE INTO counterparties tgt
        USING (
            SELECT :1 AS short_name, :2 AS long_name, :3 AS counterparty_type,
                   :4 AS country_iso2, :5 AS lei
              FROM dual
        ) src
        ON (tgt.short_name = src.short_name)
        WHEN NOT MATCHED THEN
            INSERT (counterparty_id, short_name, long_name, counterparty_type, country_iso2, lei)
            VALUES (seq_counterparty_id.NEXTVAL, src.short_name, src.long_name,
                    src.counterparty_type, src.country_iso2, src.lei)
        """,
        rows,
    )
    return len(rows)


def _load_accounts(cur) -> int:
    rows = []
    for desk_code, desk_name in DESKS:
        for book in BOOKS:
            code = f"{desk_code}_{book}"
            rows.append({
                "code":     code,
                "name":     f"{desk_name} — {book.title()} Book",
                "type":     "TRADING",
                "desk":     desk_code,
                "book":     book,
                "currency": "USD",
            })
    cur.executemany(
        """
        MERGE INTO accounts tgt
        USING (
            SELECT :code AS account_code, :name AS account_name, :type AS account_type,
                   :desk AS desk, :book AS book, :currency AS base_currency
              FROM dual
        ) src
        ON (tgt.account_code = src.account_code)
        WHEN NOT MATCHED THEN
            INSERT (account_id, account_code, account_name, account_type, desk, book, base_currency)
            VALUES (seq_account_id.NEXTVAL, src.account_code, src.account_name, src.account_type,
                    src.desk, src.book, src.base_currency)
        """,
        rows,
    )
    return len(rows)


def seed_all(seed: int = 42) -> dict[str, int]:
    rng = random.Random(seed)
    with connect() as conn, conn.cursor() as cur:
        n_inst    = _load_instruments(cur, rng)
        n_brokers = _load_brokers(cur, rng)
        n_acc     = _load_accounts(cur)
        conn.commit()
    summary = {"instruments": n_inst, "brokers": n_brokers, "accounts": n_acc}
    console.print("[green]Seed loaded:[/green]", summary)
    return summary


def ticker_by_symbol(symbol: str) -> Ticker:
    for t in TICKERS:
        if t.symbol == symbol:
            return t
    raise KeyError(symbol)

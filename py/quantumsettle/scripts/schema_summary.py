"""Summarize what migrate produced: tables, partitioned tables, indexes, seeds."""

from __future__ import annotations

import sys

from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect

console = Console()


def main() -> int:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM user_tables")
        tables = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM user_part_tables")
        parts = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM user_indexes WHERE index_type != 'LOB'")
        indexes = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM user_constraints WHERE constraint_type = 'R'")
        fks = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM user_sequences")
        seqs = cur.fetchone()[0]

        cur.execute("""
            SELECT table_name, partitioning_type, interval
              FROM user_part_tables
             ORDER BY table_name
        """)
        partitioned = cur.fetchall()

        cur.execute(
            "SELECT 'currencies',     COUNT(*) FROM currencies     UNION ALL "
            "SELECT 'exchanges',      COUNT(*) FROM exchanges      UNION ALL "
            "SELECT 'instruments',    COUNT(*) FROM instruments    UNION ALL "
            "SELECT 'counterparties', COUNT(*) FROM counterparties UNION ALL "
            "SELECT 'accounts',       COUNT(*) FROM accounts       UNION ALL "
            "SELECT 'trades',         COUNT(*) FROM trades"
        )
        seeds = cur.fetchall()

    overview = Table(title="Schema overview", header_style="bold green")
    overview.add_column("Object kind"); overview.add_column("Count", justify="right")
    overview.add_row("Tables", str(tables))
    overview.add_row("Partitioned tables", str(parts))
    overview.add_row("Indexes", str(indexes))
    overview.add_row("Foreign keys", str(fks))
    overview.add_row("Sequences", str(seqs))
    console.print(overview)

    pt = Table(title="Partitioning", header_style="bold")
    pt.add_column("Table"); pt.add_column("Type"); pt.add_column("Interval")
    for name, ptype, interval in partitioned:
        pt.add_row(name, ptype, str(interval) if interval else "-")
    console.print(pt)

    sd = Table(title="Seed counts", header_style="bold")
    sd.add_column("Table"); sd.add_column("Rows", justify="right")
    for name, count in seeds:
        sd.add_row(name, str(count))
    console.print(sd)
    return 0


if __name__ == "__main__":
    sys.exit(main())

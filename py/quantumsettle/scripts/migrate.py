"""Apply all .sql files under db/01_schema .. db/04_jobs in order.

Each .sql file is split on lines containing only a forward slash ("/"),
matching SQL*Plus convention for PL/SQL block terminators. Plain DDL/DML
files without slashes are sent as a single statement.

This migrate is idempotent only if the SQL files themselves are idempotent
(use CREATE OR REPLACE, BEGIN/EXCEPTION for table-exists, etc.). Phase 1
DDL will be authored with that in mind.
"""

from __future__ import annotations

import sys
from pathlib import Path

import oracledb
from rich.console import Console

from quantumsettle.config import PROJECT_ROOT
from quantumsettle.db import connect

console = Console()

MIGRATION_DIRS = [
    "db/01_schema",       # tables, external table, constraints, MV log
    "db/02_common",       # PKG_OPS, PKG_PERF — shared infrastructure
    "db/03_mviews",       # MV_DAILY_PNL — created before the packages that read it
    "db/04_optimized",    # PKG_*_OPTIMIZED — the recommended implementations
    "db/05_not_optimized",# PKG_*_NOT_OPTIMIZED — the benchmark baselines
    "db/99_seed",         # reference data
]


def split_sql(text: str) -> list[str]:
    chunks: list[str] = []
    buf: list[str] = []
    for line in text.splitlines():
        if line.strip() == "/":
            stmt = "\n".join(buf).strip()
            if stmt:
                chunks.append(stmt)
            buf = []
        else:
            buf.append(line)
    tail = "\n".join(buf).strip().rstrip(";")
    if tail:
        chunks.append(tail)
    return chunks


def apply_file(cur: oracledb.Cursor, path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    for stmt in split_sql(text):
        try:
            cur.execute(stmt)
        except oracledb.DatabaseError as exc:
            console.print(f"[red]Error in {path.name}[/red]: {exc}")
            console.print("[yellow]Statement was:[/yellow]")
            console.print(stmt[:500] + ("..." if len(stmt) > 500 else ""))
            raise


def main() -> int:
    conn = connect()
    cur = conn.cursor()
    files_applied = 0
    try:
        for rel in MIGRATION_DIRS:
            d = PROJECT_ROOT / rel
            if not d.exists():
                continue
            files = sorted(p for p in d.iterdir() if p.suffix.lower() == ".sql")
            if not files:
                console.print(f"[dim]{rel}: nothing to apply[/dim]")
                continue
            console.print(f"[bold]{rel}[/bold]")
            for f in files:
                console.print(f"  applying {f.name} ...", end="")
                apply_file(cur, f)
                conn.commit()
                console.print(" [green]ok[/green]")
                files_applied += 1
    finally:
        cur.close()
        conn.close()

    console.print(f"\n[green]Done.[/green] {files_applied} file(s) applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

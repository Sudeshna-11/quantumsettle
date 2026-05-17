"""PL/SQL test runner.

Compiles every .sql file under tests/plsql/ (in order), then invokes each
test_* procedure in each test_pkg_* package via a single PL/SQL block. Each
assertion failure raises ORA-20100 with a descriptive message; the runner
catches per-test exceptions and emits a pytest-style summary.

Exit code: 0 if all tests pass, 1 if any fail.

  python -m quantumsettle.scripts.run_tests
  python -m quantumsettle.scripts.run_tests --verbose
"""

from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import click
import oracledb
from rich.console import Console
from rich.table import Table

from quantumsettle.config import PROJECT_ROOT
from quantumsettle.db import connect

console = Console()

TESTS_DIR = PROJECT_ROOT / "tests" / "plsql"


@dataclass
class TestResult:
    suite: str
    name: str
    status: str   # "PASS" or "FAIL"
    elapsed_ms: int
    error: str | None = None


def _apply_sql_file(conn: oracledb.Connection, path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    buf: list[str] = []
    with conn.cursor() as cur:
        for line in text.splitlines():
            if line.strip() == "/":
                stmt = "\n".join(buf).strip()
                if stmt:
                    cur.execute(stmt)
                buf = []
            else:
                buf.append(line)
        tail = "\n".join(buf).strip().rstrip(";")
        if tail:
            cur.execute(tail)
    conn.commit()


def _install_tests(conn: oracledb.Connection) -> list[Path]:
    files = sorted(p for p in TESTS_DIR.iterdir() if p.suffix.lower() == ".sql")
    for f in files:
        _apply_sql_file(conn, f)
    return files


def _discover_tests(conn: oracledb.Connection) -> list[tuple[str, str]]:
    """Return [(package, procedure)] for every PROCEDURE named test_* in any
    package starting with test_pkg_."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT object_name, procedure_name
              FROM user_procedures
             WHERE object_type = 'PACKAGE'
               AND object_name LIKE 'TEST\\_PKG\\_%' ESCAPE '\\'
               AND procedure_name LIKE 'TEST\\_%' ESCAPE '\\'
             ORDER BY object_name, procedure_name
        """)
        return [(r[0], r[1]) for r in cur.fetchall()]


def _run_test(conn: oracledb.Connection, pkg: str, proc: str) -> TestResult:
    t0 = time.perf_counter()
    try:
        with conn.cursor() as cur:
            cur.callproc(f"{pkg}.{proc}")
        conn.commit()
        return TestResult(pkg, proc, "PASS",
                          int((time.perf_counter() - t0) * 1000))
    except oracledb.DatabaseError as exc:
        err = str(exc).strip().splitlines()[0]
        # Strip leading "ORA-NNNNN: " for tidier display
        err = re.sub(r"^ORA-\d+:\s*", "", err)
        return TestResult(pkg, proc, "FAIL",
                          int((time.perf_counter() - t0) * 1000), err)


@click.command()
@click.option("--verbose/--quiet", default=True)
def main(verbose: bool) -> None:
    console.rule("[bold]QuantumSettle PL/SQL test suite[/bold]")
    with connect() as conn:
        files = _install_tests(conn)
        if verbose:
            console.print(f"Installed {len(files)} test file(s):")
            for f in files:
                console.print(f"  - tests/plsql/{f.name}")

        tests = _discover_tests(conn)
        if not tests:
            console.print("[yellow]No tests discovered.[/yellow]")
            sys.exit(0)

        results: list[TestResult] = []
        for pkg, proc in tests:
            r = _run_test(conn, pkg, proc)
            results.append(r)
            tag = "[green]PASS[/green]" if r.status == "PASS" else "[red]FAIL[/red]"
            console.print(f"  {tag}  {pkg}.{proc:<55} {r.elapsed_ms:>5} ms")
            if r.error and verbose:
                console.print(f"        [red]{r.error}[/red]")

    # Summary table
    passed = sum(1 for r in results if r.status == "PASS")
    failed = sum(1 for r in results if r.status == "FAIL")
    console.rule(f"[bold]{passed} passed, {failed} failed[/bold]")

    if failed:
        t = Table(title="Failures", header_style="bold red")
        t.add_column("Test"); t.add_column("Error")
        for r in results:
            if r.status == "FAIL":
                t.add_row(f"{r.suite}.{r.name}", r.error or "")
        console.print(t)
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()

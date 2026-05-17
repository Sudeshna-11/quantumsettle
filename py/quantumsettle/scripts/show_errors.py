"""Print PL/SQL compile errors for invalid objects in the schema."""

from __future__ import annotations

import sys

from rich.console import Console
from rich.table import Table

from quantumsettle.db import connect

console = Console()


def main() -> int:
    with connect() as conn, conn.cursor() as cur:
        # Force-recompile every invalid object so user_errors gets fresh entries
        cur.execute("""
            SELECT object_name, object_type
              FROM user_objects
             WHERE status = 'INVALID' AND object_type IN ('PACKAGE','PACKAGE BODY','VIEW','MATERIALIZED VIEW')
        """)
        for name, otype in cur.fetchall():
            try:
                if otype == 'PACKAGE BODY':
                    cur.execute(f"ALTER PACKAGE {name} COMPILE BODY")
                elif otype == 'PACKAGE':
                    cur.execute(f"ALTER PACKAGE {name} COMPILE")
                elif otype == 'VIEW':
                    cur.execute(f"ALTER VIEW {name} COMPILE")
                elif otype == 'MATERIALIZED VIEW':
                    cur.execute(f"ALTER MATERIALIZED VIEW {name} COMPILE")
            except Exception:
                pass  # compile errors land in user_errors below

        cur.execute("""
            SELECT object_name, object_type, status
              FROM user_objects
             WHERE status = 'INVALID'
             ORDER BY object_type, object_name
        """)
        invalid = cur.fetchall()
        if not invalid:
            console.print("[green]All objects valid.[/green]")
            return 0

        t = Table(title="Invalid objects", header_style="bold red")
        for h in ("name", "type", "status"):
            t.add_column(h)
        for r in invalid:
            t.add_row(*(str(x) for x in r))
        console.print(t)

        cur.execute("""
            SELECT name, type, line, position, text
              FROM user_errors
             ORDER BY name, type, sequence
        """)
        errs = cur.fetchall()
        for r in errs:
            console.print(f"[yellow]{r[0]} ({r[1]}) line {r[2]}, col {r[3]}:[/yellow] {r[4]}")
    return 1 if invalid else 0


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import sys

from rich.console import Console
from rich.table import Table

from quantumsettle.config import settings
from quantumsettle.db import connect

console = Console()


def main() -> int:
    console.print(f"[bold]Connecting to[/bold] {settings.db_dsn} as {settings.db_user} ...")
    try:
        conn = connect()
    except Exception as exc:
        console.print(f"[red]Connection failed:[/red] {exc}")
        console.print("Hints:")
        console.print("  - Is the container up?    [cyan]make up && make wait[/cyan]")
        console.print("  - Is .env populated?      [cyan]cp .env.example .env[/cyan]")
        console.print("  - Did the init script finish? [cyan]make logs[/cyan]")
        return 1

    with conn.cursor() as cur:
        cur.execute("""
            SELECT banner_full FROM v$version WHERE ROWNUM = 1
        """)
        banner = cur.fetchone()[0]
        cur.execute("SELECT SYS_CONTEXT('USERENV','CON_NAME') FROM dual")
        con_name = cur.fetchone()[0]
        cur.execute("SELECT default_tablespace FROM user_users")
        default_ts = cur.fetchone()[0]
        cur.execute(
            """SELECT tablespace_name,
                      CASE WHEN max_bytes = -1 THEN NULL
                           ELSE ROUND(max_bytes / 1024 / 1024, 1) END AS quota_mb
                 FROM user_ts_quotas
                ORDER BY tablespace_name"""
        )
        quotas = cur.fetchall()

    table = Table(title="Connection OK", show_header=True, header_style="bold green")
    table.add_column("Field"); table.add_column("Value")
    table.add_row("Server", banner)
    table.add_row("Container (PDB)", con_name)
    table.add_row("Default tablespace", default_ts)
    console.print(table)

    if quotas:
        q = Table(title="Tablespace quotas (this user)", header_style="bold")
        q.add_column("Tablespace"); q.add_column("Quota MB", justify="right")
        for ts, mb in quotas:
            q.add_row(ts, "UNLIMITED" if mb is None else str(mb))
        console.print(q)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

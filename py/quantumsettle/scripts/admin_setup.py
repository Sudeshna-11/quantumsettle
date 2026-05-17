"""Idempotent admin setup that runs as SYSTEM rather than the app user.

What it does (all safe to re-run):
  1. Creates QS_DATA and QS_INDEX tablespaces if missing (absolute paths
     under /opt/oracle/oradata/FREE/QSPDB/ — never relative).
  2. Grants the app user UNLIMITED quota on both.
  3. Creates the QS_STAGED directory object pointing at /opt/oracle/data/staged.
  4. Grants the app user READ + WRITE on the directory and the privileges
     PKG_REPORT / PKG_RECON / DBMS_SCHEDULER need.

Required by CI (no container init script) and also fine for local dev as a
recovery step if a container recreation lost the tablespaces.
"""

from __future__ import annotations

import sys

import oracledb
from rich.console import Console

from quantumsettle.config import settings
from quantumsettle.db import connect

console = Console()

STAGED_PATH_IN_CONTAINER = "/opt/oracle/data/staged"


CREATE_TABLESPACES = [
    """
    BEGIN
        EXECUTE IMMEDIATE q'[
            CREATE TABLESPACE QS_DATA
                DATAFILE '/opt/oracle/oradata/FREE/QSPDB/qs_data01.dbf'
                    SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 16G
                EXTENT MANAGEMENT LOCAL AUTOALLOCATE
                SEGMENT SPACE MANAGEMENT AUTO
        ]';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1543 THEN RAISE; END IF;  -- tablespace already exists
    END;
    """,
    """
    BEGIN
        EXECUTE IMMEDIATE q'[
            CREATE TABLESPACE QS_INDEX
                DATAFILE '/opt/oracle/oradata/FREE/QSPDB/qs_index01.dbf'
                    SIZE 128M AUTOEXTEND ON NEXT 32M MAXSIZE 8G
                EXTENT MANAGEMENT LOCAL AUTOALLOCATE
                SEGMENT SPACE MANAGEMENT AUTO
        ]';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1543 THEN RAISE; END IF;
    END;
    """,
]

USER_GRANTS = (
    "ALTER USER {u} DEFAULT TABLESPACE QS_DATA",
    "ALTER USER {u} QUOTA UNLIMITED ON QS_DATA",
    "ALTER USER {u} QUOTA UNLIMITED ON QS_INDEX",
    "GRANT CREATE SESSION TO {u}",
    "GRANT CREATE TABLE TO {u}",
    "GRANT CREATE VIEW TO {u}",
    "GRANT CREATE MATERIALIZED VIEW TO {u}",
    "GRANT CREATE PROCEDURE TO {u}",
    "GRANT CREATE SEQUENCE TO {u}",
    "GRANT CREATE TYPE TO {u}",
    "GRANT CREATE TRIGGER TO {u}",
    "GRANT CREATE JOB TO {u}",
    "GRANT CREATE SYNONYM TO {u}",
    "GRANT QUERY REWRITE TO {u}",
    "GRANT EXECUTE ON DBMS_APPLICATION_INFO TO {u}",
    "GRANT EXECUTE ON DBMS_SQL TO {u}",
    "GRANT EXECUTE ON DBMS_MVIEW TO {u}",
    "GRANT EXECUTE ON DBMS_LOCK TO {u}",
    "GRANT SELECT ON v_$session  TO {u}",
    "GRANT SELECT ON v_$sql      TO {u}",
    "GRANT SELECT ON v_$sql_plan TO {u}",
)

DIRECTORY_STATEMENTS = (
    f"CREATE OR REPLACE DIRECTORY qs_staged AS '{STAGED_PATH_IN_CONTAINER}'",
    "GRANT READ, WRITE ON DIRECTORY qs_staged TO {u}",
)


def _exec(cur: oracledb.Cursor, sql: str) -> None:
    try:
        cur.execute(sql)
        console.print(f"  [dim]ok[/dim]    {sql.splitlines()[0][:80]}")
    except oracledb.DatabaseError as exc:
        msg = str(exc)
        # ORA-01919 user not found (already granted-style mismatch),
        # ORA-31685 already granted,
        # ORA-01749 cannot grant to self,
        # ORA-01031 insufficient privileges — SYS-owned object grants survive
        #   from the original first-boot bootstrap; SYSTEM can't redo them.
        # ORA-00942 — V$ views aren't visible to SYSTEM; the original SYS-run
        # init script granted them. Local dev already has them; CI doesn't need
        # them (perf harness V$ queries aren't part of the test suite).
        if any(code in msg for code in
               ("ORA-01919", "ORA-31685", "ORA-01749", "ORA-01031", "ORA-00942")):
            console.print(f"  [yellow]skip[/yellow]  {sql.splitlines()[0][:80]} "
                          f"[dim]({msg.splitlines()[0][:40]})[/dim]")
        else:
            console.print(f"  [red]FAIL[/red]  {sql.splitlines()[0][:80]}\n    {msg}")
            raise


def main() -> int:
    u = settings.db_user
    console.print(f"[bold]Admin setup as[/bold] {settings.db_admin_user} "
                  f"for app user [cyan]{u}[/cyan]")
    with connect(admin=True) as conn, conn.cursor() as cur:
        console.print("[bold]Tablespaces[/bold]")
        for stmt in CREATE_TABLESPACES:
            _exec(cur, stmt.strip())
        console.print("[bold]User grants[/bold]")
        for stmt in USER_GRANTS:
            _exec(cur, stmt.format(u=u))
        console.print("[bold]Directory[/bold]")
        for stmt in DIRECTORY_STATEMENTS:
            _exec(cur, stmt.format(u=u))
        conn.commit()
    console.print("[green]Done.[/green]")
    return 0


if __name__ == "__main__":
    sys.exit(main())

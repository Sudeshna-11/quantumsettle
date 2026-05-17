from collections.abc import Iterator
from contextlib import contextmanager

import oracledb

from quantumsettle.config import settings


def connect(admin: bool = False) -> oracledb.Connection:
    user = settings.db_admin_user if admin else settings.db_user
    password = settings.db_admin_password if admin else settings.db_password
    if not password:
        raise RuntimeError(
            f"Missing password for {'admin' if admin else 'app'} user. "
            "Set QS_DB_PASSWORD (or QS_DB_ADMIN_PASSWORD) in .env."
        )
    return oracledb.connect(user=user, password=password, dsn=settings.db_dsn)


@contextmanager
def cursor(admin: bool = False) -> Iterator[oracledb.Cursor]:
    conn = connect(admin=admin)
    try:
        cur = conn.cursor()
        try:
            yield cur
            conn.commit()
        finally:
            cur.close()
    finally:
        conn.close()

"""Launch the QuantumSettle FastAPI dashboard.

  python -m quantumsettle.api.run                 # http://127.0.0.1:8000
  python -m quantumsettle.api.run --port 8080
  python -m quantumsettle.api.run --reload        # hot-reload templates + code
"""

from __future__ import annotations

import click
import uvicorn


@click.command()
@click.option("--host", default="127.0.0.1", show_default=True)
@click.option("--port", default=8000, show_default=True, type=int)
@click.option("--reload/--no-reload", default=False,
              help="Auto-reload on code/template changes (dev only).")
def main(host: str, port: int, reload: bool) -> None:
    uvicorn.run("quantumsettle.api.main:app", host=host, port=port, reload=reload,
                log_level="info")


if __name__ == "__main__":
    main()

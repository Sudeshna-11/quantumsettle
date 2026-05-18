# QuantumSettle

[![CI](https://github.com/Sudeshna-11/quantumsettle/actions/workflows/ci.yml/badge.svg)](https://github.com/Sudeshna-11/quantumsettle/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Oracle](https://img.shields.io/badge/Oracle-23ai-red)
![Python](https://img.shields.io/badge/Python-3.11%2B-blue)

> **A focused PL/SQL optimisation showcase on Oracle 23ai.**
> Three phases — Ingest, Process, Report — each shipped in two flavours
> ("Optimized" and "Not Optimized") so the benchmark prints the speedup
> and the EXPLAIN PLAN shows you why.

## Why this project exists

This project shows you **two** ways for every phase and measures the gap,
so the question "why FORALL instead of a cursor loop?" gets an actual
number instead of a hand-wave.

The headline win is **partition pruning** in Phase 2 — the optimized
`UPDATE` touches one monthly partition, the not-optimized one scans every
partition on every row. At 20,000 trades that is roughly 5× on the Process
phase alone.

## Reading order

If you're just landing here:

1. **[`docs/flow.md`](docs/flow.md)** — the three-phase pipeline with a
   colour-coded Mermaid diagram and a step-by-step walkthrough.
2. **[`docs/perf-story.md`](docs/perf-story.md)** — auto-generated EXPLAIN
   PLAN comparison. The plans are the evidence; the numbers in the table
   below are the result.
3. **The package headers themselves** — each SQL package opens with a clear
   `Purpose:` / `Overview:` block.

## Phase progress

| Phase   | What it shows                                                | Optimisation technique                             |
|---------|--------------------------------------------------------------|----------------------------------------------------|
| Phase 1 | Load a staged CSV into a partitioned table                   | `BULK COLLECT` + `FORALL` + `SAVE EXCEPTIONS`      |
| Phase 2 | Derive two columns in bulk for every trade on a date         | Set-based `UPDATE` + **partition pruning**         |
| Phase 3 | Daily P&L per account                                        | Materialized view with query rewrite               |

## Headline benchmark (20,000 trades over 5 business days)

| Phase   | 🟩 Optimized | 🟦 Not optimized | Speedup |
|---------|------------:|----------------:|--------:|
| INGEST  |      2.18 s |          2.85 s |    1.3× |
| PROCESS |      1.55 s |          7.56 s |  **4.9×** |
| REPORT  |      0.01 s |          0.01 s |    1.9× |
| **TOTAL** |    **3.73 s** |   **10.42 s** |  **2.8×** |

Reproduce locally:

```bash
python -m quantumsettle.bench.run --trades 20000 --days 5
python -m quantumsettle.bench.explain    # regenerates docs/perf-story.md
```

## Quickstart

```bash
# 1. Configure secrets
cp .env.example .env       # then edit strong passwords

# 2. Start Oracle 23ai Free in Docker (first boot ~3-4 min)
docker compose up -d
.\tasks.ps1 wait

# 3. Install the Python package
pip install -e ".[dev]"

# 4. Apply schema, packages, MV, seeds
python -m quantumsettle.scripts.admin_setup
python -m quantumsettle.scripts.migrate

# 5. Generate fake trades + run the pipeline
python -m quantumsettle.faker.run all --days 5 --trades-per-day 1000
python -m quantumsettle.scripts.ingest  load   --variant optimized trades_*.csv
python -m quantumsettle.scripts.process run-all --variant optimized
python -m quantumsettle.scripts.report  pnl    --variant optimized --date 2026-05-12

# 6. Benchmark + dashboard
python -m quantumsettle.bench.run --trades 20000 --days 5
python -m quantumsettle.api.run  --port 8765      # http://127.0.0.1:8765
```

On Windows substitute `.\tasks.ps1 <target>` for `make <target>`.

## Tech stack

| Layer          | Choice                                                      |
|----------------|-------------------------------------------------------------|
| Database       | Oracle Database 23ai Free (Docker, `gvenzl/oracle-free:23-slim`) |
| Language       | Python 3.11+                                                |
| DB driver      | `python-oracledb` thin mode — no Oracle Instant Client      |
| API            | FastAPI                                                     |
| UI             | Jinja2 server-rendered + Bootstrap 5 + Chart.js (all via CDN) |
| DB tests       | utPLSQL-style assertions in plain PL/SQL                    |
| Python tests   | pytest                                                      |
| CI             | GitHub Actions with Oracle service container                |

## Image + PDB naming gotcha (read once, save time later)

This repo uses `gvenzl/oracle-free:23-slim` with the pluggable database
named **`QSPDB`**, not `FREEPDB1`. Every `gvenzl/oracle-free:23*` variant
ships with `FREEPDB1` already created — and the image's init flow
unconditionally runs `CREATE PLUGGABLE DATABASE`, which then collides with
`ORA-65012` and silently aborts the rest of init (including the user's
bootstrap scripts and the automatic APP_USER creation). Using a project-
specific PDB name sidesteps this.

## Repository layout

```
db/                          PL/SQL source — six numbered folders
  00_bootstrap/              tablespaces + grants (runs at container init)
  01_schema/                 tables + external table + MV log + constraints
  02_common/                 PKG_OPS, PKG_PERF — shared infrastructure
  03_mviews/                 MV_DAILY_PNL
  04_optimized/              PKG_INGEST_OPTIMIZED, PKG_PROCESS_OPTIMIZED,
                             PKG_REPORT_OPTIMIZED  (the recommended path)
  05_not_optimized/          deliberately-slow variants for the benchmark
  99_seed/                   reference data
py/quantumsettle/            CLI, faker, bench, FastAPI dashboard
tests/plsql/                 PL/SQL unit tests (assertion-style)
tests/py/                    pytest smoke tests
docs/                        flow.md, perf-story.md
.github/workflows/ci.yml     full schema + test run on every push
```

## CI

`.github/workflows/ci.yml` boots Oracle 23ai as a service container, applies
the full schema, seeds reference data and runs both the PL/SQL test suite and
the pytest smoke tests on every push and pull request.

## License

MIT.

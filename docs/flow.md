# QuantumSettle — end-to-end flow

This document explains the three-phase pipeline and which package handles
which phase. Read it first if you just cloned the repo.

## The 30-second pitch

QuantumSettle is a focused demonstration of PL/SQL performance optimisation.
A trade CSV lands in a staging area, the database loads it, enriches it with
derived columns, and serves a daily P&L report. **Each phase ships in two
flavours — Optimized and Not Optimized — so the same workload runs two ways
and the benchmark prints the speedup.**

## The 3-phase pipeline

```mermaid
flowchart LR
    classDef opt    fill:#1b5e20,stroke:#0f3d12,color:#ffffff,font-weight:bold;
    classDef notopt fill:#0d3b66,stroke:#08233d,color:#ffffff,font-weight:bold;
    classDef src    fill:#37474f,stroke:#1d272d,color:#ffffff;
    classDef tgt    fill:#455a64,stroke:#263238,color:#ffffff;
    classDef mv     fill:#5d4037,stroke:#321c19,color:#ffffff;

    F[Python faker]:::src
    CSV[(staged trades.csv)]:::src
    EXT[EXT_TRADES<br/>external table]:::tgt

    IOPT[PKG_INGEST_OPTIMIZED<br/>FORALL + SAVE EXCEPTIONS]:::opt
    INOT[PKG_INGEST_NOT_OPTIMIZED<br/>cursor FOR loop]:::notopt

    POPT[PKG_PROCESS_OPTIMIZED<br/>set-based UPDATE<br/>partition pruned]:::opt
    PNOT[PKG_PROCESS_NOT_OPTIMIZED<br/>row-by-row UPDATE<br/>no pruning]:::notopt

    TR[(trades<br/>partitioned by trade_date)]:::tgt
    MV[(MV_DAILY_PNL<br/>fast-refresh on commit)]:::mv

    ROPT[PKG_REPORT_OPTIMIZED<br/>reads MV]:::opt
    RNOT[PKG_REPORT_NOT_OPTIMIZED<br/>NO_REWRITE GROUP BY]:::notopt

    PERF((perf_metrics and<br/>FastAPI dashboard))

    F --> CSV --> EXT
    EXT --> IOPT
    EXT --> INOT
    IOPT --> TR
    INOT --> TR
    TR --> POPT
    TR --> PNOT
    POPT --> TR
    PNOT --> TR
    TR --> MV
    MV --> ROPT
    TR --> RNOT
    ROPT --> PERF
    RNOT --> PERF

    linkStyle default stroke:#ffffff,stroke-width:2px,color:#ffffff;
```

**Legend:**
- 🟩 **Dark green** — the *Optimized* implementation. Use these in production.
- 🟦 **Deep blue** — the *Not Optimized* implementation. Exists only as a
  benchmark baseline.
- ⬛ Grey — raw inputs and core tables.
- 🟫 Brown — the materialized view.

## Step-by-step

### Phase 0 — bring up Oracle (one-time per machine)

```bash
docker compose up -d
.\tasks.ps1 wait                # wait for the healthcheck
pip install -e ".[dev]"
python -m quantumsettle.scripts.admin_setup   # tablespaces, grants, directory
python -m quantumsettle.scripts.migrate       # schema + packages + MV + seeds
```

Two non-obvious settings (both learnt the hard way; both encoded in the
shipped files now):
- The pluggable database is named **`QSPDB`**, not `FREEPDB1`. The `gvenzl`
  image ships with a pre-created `FREEPDB1` and the init flow silently fails
  if you ask it to create another one with that name.
- Tablespace datafiles use **absolute paths** under `/opt/oracle/oradata/...`
  Relative paths would land in `$ORACLE_HOME/dbs/` (ephemeral) and be lost
  on the next `docker compose down`.

### Step 1 — generate a trade CSV

```bash
python -m quantumsettle.faker.run all --days 5 --trades-per-day 1000
```

- `seed_all` MERGEs 50 instruments, 12 brokers and 20 accounts into the
  reference tables (idempotent).
- `iter_trades` produces trades with a U-shaped intraday distribution and a
  lognormal quantity. Real US ticker symbols, plausible price bands.
- Writes one CSV: `data/staged/trades_<start>_<end>.csv`.
- The CSV **does not** include `settlement_date` or `net_amount` — those are
  *derived* by Phase 2, not supplied by the feed.

### Step 2 — Ingest (Phase 1)

```bash
python -m quantumsettle.scripts.ingest load --variant optimized      <csv>
python -m quantumsettle.scripts.ingest load --variant not-optimized  <csv>
```

| Variant | What it does |
|---------|--------------|
| 🟩 Optimized | `BULK COLLECT` from `EXT_TRADES` in 5,000-row chunks, single `FORALL ... SAVE EXCEPTIONS INSERT` per chunk, one row per rejection in `INGEST_ERRORS`. |
| 🟦 Not optimized | Cursor `FOR LOOP`, one `INSERT` per row, no `SAVE EXCEPTIONS`. |

Either way, when this phase finishes, `trades` has the raw rows. `processed`
is `'N'`. `net_amount` and `settlement_date` are still `NULL`.

### Step 3 — Process (Phase 2)

```bash
python -m quantumsettle.scripts.process run-all --variant optimized
python -m quantumsettle.scripts.process run-all --variant not-optimized
```

Derives the two missing columns in bulk and flips `processed` to `'Y'`:
- `net_amount = gross_amount ± commission`  (sign depends on `side`)
- `settlement_date = trade_date + 2`  (rolled forward over weekends)

| Variant | SQL shape |
|---------|-----------|
| 🟩 Optimized | One set-based `UPDATE trades SET ... WHERE trade_date = :d AND processed = 'N'` per date. The partition-key predicate means **one partition opened**. |
| 🟦 Not optimized | Cursor `FOR LOOP`, one `UPDATE trades SET ... WHERE trade_id = :id` per trade. No `trade_date` in the WHERE → **every partition opened on every UPDATE**. |

The not-optimized variant produces identical results but pays the partition-
pruning loss on every row. This is the headline win in `docs/perf-story.md`.

### Step 4 — Report (Phase 3)

```bash
python -m quantumsettle.scripts.report pnl --variant optimized      --date 2026-05-12
python -m quantumsettle.scripts.report pnl --variant not-optimized  --date 2026-05-12
```

| Variant | Strategy |
|---------|----------|
| 🟩 Optimized | Reads from `MV_DAILY_PNL`, the fast-refresh-on-commit materialized view. A handful of pre-aggregated rows. |
| 🟦 Not optimized | Full `GROUP BY` against the base `trades` table, with the `NO_REWRITE` hint so the planner is forced to actually do the work rather than substitute the MV. |

Same numbers, different cost — and the cost grows linearly with data volume
on the not-optimized side and stays flat on the optimized side.

### Step 5 — Benchmark + dashboard

```bash
python -m quantumsettle.bench.run --trades 20000 --days 5    # timings → perf_metrics
python -m quantumsettle.bench.explain                        # plans → docs/perf-story.md
python -m quantumsettle.api.run --port 8765                  # dashboard
```

The benchmark runs the full pipeline twice and prints a speedup table. The
EXPLAIN PLAN runner generates a side-by-side markdown report showing *why*
the optimized version wins. The dashboard reads `perf_metrics` and renders
a Chart.js bar chart at `http://127.0.0.1:8765/perf`.

## File map

```
db/00_bootstrap/   tablespaces + grants (runs once at container init)
db/01_schema/      tables, external table, constraints, MV log
db/02_common/      PKG_OPS, PKG_PERF (shared by both variants)
db/03_mviews/      MV_DAILY_PNL
db/04_optimized/   PKG_INGEST_OPTIMIZED, PKG_PROCESS_OPTIMIZED, PKG_REPORT_OPTIMIZED
db/05_not_optimized/ same three packages, deliberately slow
db/99_seed/        reference data (currencies, exchanges)

py/quantumsettle/
  faker/           trade CSV generator + reference-data seed
  scripts/         admin_setup, migrate, check_db, schema_summary,
                   ingest, process, report, run_tests, show_errors
  bench/           run.py (timing harness), explain.py (plan capture)
  api/             FastAPI + Jinja2 dashboard

tests/plsql/       6 PL/SQL unit tests across 3 packages
tests/py/          pytest smoke tests
docs/              flow.md (this file), perf-story.md
.github/workflows/ ci.yml — full schema + tests on every push
```

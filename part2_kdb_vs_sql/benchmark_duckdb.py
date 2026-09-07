"""
DuckDB benchmark half of the KDB+/Q vs SQL comparison project.

Runs the same 5 queries as benchmark_q.q against the London smart-meter
half-hourly dataset, timing each one, and writes results to results_duckdb.csv
(written next to this script, NOT into the data folder).

The dataset itself is not part of this repo (too large for git) — point
this script at it either by setting the SQL_KDB_DATA_DIR environment
variable, or by editing DEFAULT_DATA_DIR below.

Usage:
    python benchmark_duckdb.py [N_BLOCKS] [N_REPEATS]

    N_BLOCKS   how many block_*.csv files to load (default 1, max 112)
    N_REPEATS  how many times to repeat each query for timing (default 5)
"""

import os
import sys
import time
import glob
import statistics
import csv
from pathlib import Path

import duckdb

# Edit this if your dataset lives somewhere else, or set the
# SQL_KDB_DATA_DIR environment variable instead (takes priority).
DEFAULT_DATA_DIR = "/mnt/c/Users/slast/Videos/09_proj_sql_VS_kdb"

DATA_DIR = Path(os.environ.get("SQL_KDB_DATA_DIR", DEFAULT_DATA_DIR))
OUT_DIR = Path(__file__).resolve().parent  # results are written next to the code

HALFHOURLY_DIR = DATA_DIR / "halfhourly_dataset" / "halfhourly_dataset"
HOUSEHOLDS_CSV = DATA_DIR / "informations_households.csv"

N_BLOCKS = int(sys.argv[1]) if len(sys.argv) > 1 else 1
N_REPEATS = int(sys.argv[2]) if len(sys.argv) > 2 else 5

# Fixed household id used for the point-filter query, so both engines
# benchmark the exact same lookup rather than each picking their own.
SAMPLE_LCLID = "MAC000002"


def time_query(con, label, sql, repeats=N_REPEATS):
    times = []
    result = None
    for _ in range(repeats):
        t0 = time.perf_counter()
        result = con.execute(sql).fetchall()
        times.append((time.perf_counter() - t0) * 1000.0)  # ms
    avg_ms = statistics.mean(times)
    print(f"  {label:<45} avg {avg_ms:9.2f} ms   (n_result_rows={len(result)}, {repeats} reps)")
    return label, avg_ms, len(result)


def main():
    print(f"Data directory: {DATA_DIR}")
    if not HALFHOURLY_DIR.exists():
        raise SystemExit(
            f"Dataset not found at {HALFHOURLY_DIR}\n"
            f"Set SQL_KDB_DATA_DIR to the folder containing halfhourly_dataset/, "
            f"or edit DEFAULT_DATA_DIR at the top of this script."
        )

    block_files = sorted(
        glob.glob(str(HALFHOURLY_DIR / "block_*.csv")),
        key=lambda p: int(Path(p).stem.split("_")[1]),
    )[:N_BLOCKS]
    if not block_files:
        raise SystemExit(f"No block_*.csv files found under {HALFHOURLY_DIR}")

    print(f"Loading {len(block_files)} block file(s) into DuckDB (in-memory)...")
    con = duckdb.connect(database=":memory:")

    t0 = time.perf_counter()
    files_sql = "[" + ", ".join(f"'{f}'" for f in block_files) + "]"
    con.execute(f"""
        CREATE TABLE readings AS
        SELECT
            LCLid,
            CAST(tstp AS TIMESTAMP) AS tstp,
            TRY_CAST(TRIM("energy(kWh/hh)") AS DOUBLE) AS energy_kwh
        FROM read_csv_auto({files_sql}, header=True)
    """)
    con.execute(f"""
        CREATE TABLE households AS
        SELECT * FROM read_csv_auto('{HOUSEHOLDS_CSV}', header=True)
    """)
    load_ms = (time.perf_counter() - t0) * 1000.0
    n_rows = con.execute("SELECT COUNT(*) FROM readings").fetchone()[0]
    n_null = con.execute("SELECT COUNT(*) FROM readings WHERE energy_kwh IS NULL").fetchone()[0]
    print(f"Loaded {n_rows:,} rows in {load_ms:,.1f} ms ({n_null} unparseable/Null energy values -> NULL)\n")

    results = [("load_data", load_ms, n_rows)]

    print("Running queries...")
    results.append(time_query(con, "Q1 full_count", "SELECT COUNT(*) FROM readings"))

    results.append(time_query(
        con, "Q2 point_filter (single household)",
        f"SELECT COUNT(*), AVG(energy_kwh) FROM readings WHERE LCLid = '{SAMPLE_LCLID}'",
    ))

    results.append(time_query(
        con, "Q3 groupby_household (avg per LCLid)",
        "SELECT LCLid, AVG(energy_kwh) AS avg_kwh FROM readings GROUP BY LCLid",
    ))

    results.append(time_query(
        con, "Q4 groupby_hour_of_day",
        "SELECT EXTRACT(hour FROM tstp) AS hh, AVG(energy_kwh) AS avg_kwh "
        "FROM readings GROUP BY hh ORDER BY hh",
    ))

    results.append(time_query(
        con, "Q5 join_groupby_acorn",
        "SELECT h.Acorn_grouped, AVG(r.energy_kwh) AS avg_kwh "
        "FROM readings r JOIN households h USING (LCLid) "
        "GROUP BY h.Acorn_grouped",
    ))

    out_csv = OUT_DIR / "results_duckdb.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["engine", "n_blocks", "query", "avg_ms", "n_result_rows"])
        for label, ms, nrows in results:
            w.writerow(["duckdb", N_BLOCKS, label, f"{ms:.2f}", nrows])
    print(f"\nResults written to {out_csv}")


if __name__ == "__main__":
    main()

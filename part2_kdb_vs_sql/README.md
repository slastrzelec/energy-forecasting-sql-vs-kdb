# Part 2 — KDB+/Q vs SQL (DuckDB) performance comparison

Runs the same 5 queries against the London smart-meter half-hourly dataset
in both KDB-X (kdb+/q) and DuckDB, entirely locally (no AWS), to give a fair
same-hardware comparison. Part 1 of this project (`../` — S3/Athena/Prophet)
already demonstrates cloud/AWS skills, so this half is deliberately local.

## Dataset

Not included in this repo (too large for git). It's the "Smart meters in
London" dataset (Kaggle: `jeanmidev/smart-meters-in-london`), long-format
half-hourly readings (`LCLid`, `tstp`, `energy(kWh/hh)`), ~167M rows across
112 `block_*.csv` files, plus `informations_households.csv` (household →
Acorn socioeconomic group mapping).

Both scripts look for the dataset at:
```
/mnt/c/Users/slast/Videos/09_proj_sql_VS_kdb
```
Override with the `SQL_KDB_DATA_DIR` environment variable if it moves, e.g.:
```bash
export SQL_KDB_DATA_DIR=/mnt/c/Users/slast/Videos/09_proj_sql_VS_kdb
```

## Running

From WSL (Ubuntu), inside this folder:

```bash
# DuckDB
source ~/kdb-project-env/bin/activate
python3 benchmark_duckdb.py 1 5      # 1 block (~1.2M rows), 5 repeats

# KDB+/Q
q benchmark_q.q 1 5
```

Both args are optional: `[n_blocks] [n_repeats]`, defaulting to `1 5`.
Once queries and results look right on 1 block, scale up (e.g. `10`, then
all `112`) for the real headline numbers.

## What's measured

Both engines run the identical 5 queries and report the **average of N
repeated runs** in milliseconds, so the comparison is apples-to-apples:

1. `Q1` — full row count
2. `Q2` — point filter: single household (`LCLid = MAC000002`, fixed in both
   scripts so it's the same lookup)
3. `Q3` — aggregation: avg energy per household (`GROUP BY LCLid`)
4. `Q4` — time aggregation: avg energy by hour of day
5. `Q5` — join + aggregation: join with household metadata, avg energy by
   Acorn socioeconomic group

Load time (reading the CSV(s) into memory) is recorded separately from the
5 timed queries, since it's a one-off cost rather than something a real
query workload repeats.

Results are written to `results_duckdb.csv` and `results_q.csv` in this
folder (not into the data folder). Note `results_q.csv` has one column
fewer (`n_result_rows` isn't captured on the q side — q's `\t:n` timing
mechanism only returns elapsed time, not the query result itself).

## Known data quality issue

A small number of rows (50 in `block_0.csv`) have the literal string
`"Null"` instead of a numeric value in the energy column. Both scripts
convert these to a proper NULL rather than erroring — worth mentioning
in the writeup as a deliberate data-cleaning decision, not an oversight.

## Status

`benchmark_duckdb.py` has been run against real data and confirmed working.
`benchmark_q.q` has **not** been run yet (no q available outside the user's
own machine) — first real run may need small fixes.

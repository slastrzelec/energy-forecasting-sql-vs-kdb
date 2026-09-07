// KDB+/Q benchmark half of the SQL vs KDB+/Q comparison project.
// Mirrors the 5 queries in benchmark_duckdb.py against the same
// London smart-meter half-hourly dataset.
//
// The dataset itself is not part of this repo (too large for git) —
// point this script at it either by setting the SQL_KDB_DATA_DIR
// environment variable, or by editing defaultDataDir below.
//
// Usage:
//   q benchmark_q.q [nBlocks] [nRepeats]
//   (defaults: 1 block, 5 repeats — matches benchmark_duckdb.py defaults)

args: .z.x
nBlocks: $[count args; "I"$first args; 1]
nRepeats: $[1 < count args; "I"$args 1; 5]

defaultDataDir: "/mnt/c/Users/slast/Videos/09_proj_sql_VS_kdb"
envDataDir: string getenv `SQL_KDB_DATA_DIR
dataDir: $[0 = count envDataDir; defaultDataDir; envDataDir]
-1 "Data directory: ", dataDir;

// same fixed household id used in benchmark_duckdb.py, so both engines
// benchmark the identical lookup
sampleLclid: `MAC000002

-1 "Loading ", string[nBlocks], " block file(s) into kdb+ (in-memory)...";

// ---- load one half-hourly block CSV into a clean 3-column table ----------
// NOTE: 0: with an explicit type string already returns a table, with
// column names taken from the CSV header row (LCLid / tstp / energy(kWh/hh)).
// The energy column name has punctuation in it, so it's accessed via
// t[`$"energy(kWh/hh)"] rather than t`energy(kWh/hh) (not valid q syntax).
loadBlock: {[f]
    t: ("S**"; enlist ",") 0: f;
    lclid: t `LCLid;
    tstpRaw: t `tstp;
    energyRaw: t[`$"energy(kWh/hh)"];
    // "2012-10-12 00:30:00.0000000" -> take first 19 chars, "-"->"." " "->"D"
    tsClean: {ssr[x; " "; "D"]} each {ssr[x; "-"; "."]} each 19#'tstpRaw;
    tstp: "P"$tsClean;
    energy: "F"$ {ssr[x; "Null"; "0n"]} each energyRaw;
    flip `LCLid`tstp`energy_kwh! (lclid; tstp; energy)
    };

blockPaths: {hsym `$ dataDir, "/halfhourly_dataset/halfhourly_dataset/block_", string[x], ".csv"} each til nBlocks

t0: .z.p
readings: raze loadBlock each blockPaths;
loadMs: 1e-6 * `long$(.z.p - t0)
-1 "Loaded ", (string count readings), " rows in ", (string loadMs), " ms";

// ---- set a grouped attribute on LCLid ------------------------------------
// LCLid isn't sorted (rows are interleaved across households by time), so
// without an attribute, filtering/grouping by LCLid is a plain linear scan.
// `g# builds a hash-based grouping index without needing the data sorted —
// timed separately since it's a one-off cost, like loading.
t0: .z.p
readings: update `g#LCLid from readings;
attrMs: 1e-6 * `long$(.z.p - t0)
-1 "Set `g#LCLid attribute in ", (string attrMs), " ms";

// households: 0: already returns this as a clean 5-column table
// (LCLid / stdorToU / Acorn / Acorn_grouped / file) from the CSV header
households: ("SSSSS"; enlist ",") 0: hsym `$ dataDir, "/informations_households.csv"
hh: `LCLid xkey select LCLid, Acorn_grouped from households

// ---- the 5 queries, as real compiled functions (not strings) -------------
// mirrors benchmark_duckdb.py's 5 queries exactly
q1f: {count readings};
q2f: {select count i, avg energy_kwh from readings where LCLid=sampleLclid};
q3f: {select avg energy_kwh by LCLid from readings};
q4f: {select avg energy_kwh by hh:tstp.hh from readings};
q5f: {select avg energy_kwh by Acorn_grouped from readings lj hh};

// Q4 alternative: extract hour via minute-of-day cast + integer division,
// instead of the .hh temporal field accessor on a full nanosecond
// timestamp. Kept separate (not swapped into q4f) so the main comparison
// stays apples-to-apples with benchmark_duckdb.py's EXTRACT(hour FROM tstp).
q4f_alt: {select avg energy_kwh by hh:(`int$`minute$tstp) div 60 from readings};

// ---- timing helper ---------------------------------------------------
// calls f (a 0-arg lambda) reps times back-to-back, timing the whole loop
// with .z.p timestamps (no string parsing inside the loop), then reports
// the AVERAGE elapsed ms per call — same statistic as the DuckDB script.
timeIt: {[label; reps; f]
    tStart: .z.p;
    do[reps; f[]];
    elapsedMs: 1e-6 * `long$(.z.p - tStart);
    avgMs: elapsedMs % reps;
    -1 "  ", (string label), " avg ", (string avgMs), " ms  (", (string reps), " reps)";
    (label; avgMs)
    };

results: (enlist (`load_data; loadMs)), enlist (`set_g_attr_LCLid; attrMs);

-1 "Running queries...";

results,: enlist timeIt[`Q1_full_count; nRepeats; q1f];
results,: enlist timeIt[`Q2_point_filter; nRepeats; q2f];
results,: enlist timeIt[`Q3_groupby_household; nRepeats; q3f];
results,: enlist timeIt[`Q4_groupby_hour_of_day; nRepeats; q4f];
results,: enlist timeIt[`Q4_alt_groupby_hour_of_day; nRepeats; q4f_alt];
results,: enlist timeIt[`Q5_join_groupby_acorn; nRepeats; q5f];

// sanity check: Q4 and Q4_alt should agree on the actual numbers, not just
// timing — compare their results once (not timed). Sum across groups
// rather than comparing row-by-row, since grouped results from two
// different expressions aren't guaranteed to come back in the same order.
q4Result: q4f[];
q4AltResult: q4f_alt[];
-1 "Q4 sum of group averages: ", string sum exec energy_kwh from q4Result;
-1 "Q4_alt sum of group averages: ", string sum exec energy_kwh from q4AltResult;
-1 "(should be close to equal if both are extracting the same hour-of-day)";

resultsTable: flip `engine`n_blocks`query`avg_ms! (
    (count results)#`kdb;
    (count results)#nBlocks;
    first each results;
    last each results
    )

// results are written next to this script (not into the data folder)
`:results_q.csv 0: csv 0: resultsTable
-1 "Results written to results_q.csv";

exit 0

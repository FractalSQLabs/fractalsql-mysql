<p align="center">
  <img src="../FractalSQLforMySQL.jpg" alt="FractalSQL for MySQL" width="720">
</p>

# FractalSQL benchmark: native VECTOR(n) exact scan vs Scout Mode

Head-to-head comparison of MySQL's own built-in `VECTOR(n)` column type
against FractalSQL's `fractal_search_explore` (Scout Mode, `walk=0`). Measures
search latency and island recall on a synthetic Gaussian-cluster dataset.
This is a research/methodology comparison, distinct from
[`bench/tester/`](tester/)'s raw `fractal_search()` latency-percentile
throughput driver.

One framing note up front: this is an **exact scan**, not an ANN-index
comparison, and on MySQL not even an in-server sort. Community MySQL
(9.7 LTS and 26.7 alike, verified live) has no vector
index AND no distance function of any name (`DISTANCE`,
`COSINE_DISTANCE`, `VECTOR_DISTANCE` are all HeatWave-only, see
`src/fractalsql_vector.c`'s header), so the native arm here is the
closest built-in equivalent: the server streams the `VECTOR(n)` column
out with `VECTOR_TO_STRING()` and the client ranks the top-k in
numpy. The comparison is native-exact-scan vs Scout Mode, not
index-vs-no-index.
On 8.4 LTS there is no `VECTOR` type at all, and every script here
self-detects and degrades gracefully (Scout-only numbers, no native
arm).

## Prerequisites

- MySQL 8.4 LTS, 9.7 LTS, or 26.7, with FractalSQL
  installed (the example output
  below is from a prior benchmark run -- treat the exact numbers as
  representative, not freshly re-measured). The native-`VECTOR(n)`
  comparison arm additionally needs MySQL 9.7/26.7 (9.0+).
- Python 3.9+
- A database you can create/drop tables in (default connection expects
  a database named `fractalsql_bench`)

## Setup

```bash
pip install -r bench/requirements.txt
mysql -uroot -p -e "CREATE DATABASE fractalsql_bench;"
```

`fractal_search_explore`/`fractal_search` (used by `head_to_head.py`) are UDFs,
registered globally by `sql/install_udf.sql` and callable from any
database once installed anywhere. `fractal_search_trajectory` (used by
`vector_type_head_to_head.py`'s search-latency arm) is a stored
PROCEDURE, not a UDF, schema-owned like any other, so it only exists
in whichever database `sql/install_udf.sql` was sourced into. If
that's not `fractalsql_demo` already, source it into `fractalsql_bench`
too (confirmed against a live server: skipping this step fails
`vector_type_head_to_head.py`'s arm (c) with `PROCEDURE
fractalsql_bench.fractal_search_trajectory does not exist`, while
`head_to_head.py` runs fine without it):

```bash
mysql -uroot -p fractalsql_bench < sql/install_udf.sql
```

## Run the benchmark

```bash
make bench BENCH_ARGS="--host 127.0.0.1 --password <root password>"
```

Or run the two steps directly:

```bash
python3 bench/data_gen.py --host 127.0.0.1 --password <root password> \
    --with-native-vector          # ~15-45s to populate 5000 rows
python3 bench/head_to_head.py --host 127.0.0.1 --password <root password>   # seconds for 5 queries at the default scale
```

## What you should see

The output is a per-query table followed by an average. This example is
from a measured run (5000 rows, dim=128), with the native arm's
exact-scan implemented as the server-streams/client-ranks approach
described above, because MySQL Community has no in-server distance
function to order by:

```
Benchmark: 5000 stored vectors, 50 clusters, dim=128
  Native VECTOR(n) exact scan: available, LIMIT 50
  Scout (fractal_search_explore): population=50, iterations=8, mdn=2, walk=0.0 (brute-force relevance scan + MMR)

qi  anchor      |     Native ms   Native recall  |     Scout ms   Scout recall
--------------------------------------------------------------------------------
 0  cluster  23 |        5.5      1 / 50     |      227.1      5 / 50
 1  cluster  25 |        3.1      1 / 50     |      183.1      5 / 50
 2  cluster  37 |        5.9      1 / 50     |      190.6      5 / 50
 3  cluster  47 |        4.3      1 / 50     |      193.8      6 / 50
 4  cluster   1 |        4.0      2 / 50     |      192.9      7 / 50

Averages over 5 queries:
  Native:     4.6 ms   recall  1.2 / 50
  Scout:    197.5 ms   recall  5.6 / 50
  Scout is 43.3x slower and discovers 4.7x more distinct clusters
```

The shape of the result will vary run to run, but the pattern is robust and
consistent: the native
exact scan finds ~1 cluster at single-digit-millisecond latency; Scout
Mode finds 5-7 clusters at ~200ms. Same story, different technology,
different algorithms solving different problems.

## Why such a small default N

`data_gen.py` defaults to **5000 rows, dim=128**, while a large-corpus ANN
benchmark would default to 100,000 rows, dim=768. This is not a smaller-is-easier choice,
it's architectural: `fractal_search_explore()` (Scout Mode) takes its **entire**
corpus as one client-supplied inline string argument on every call. MySQL's
C UDF ABI has no server-side table access and no table-returning UDFs at all
(see `sql/install_udf.sql`'s own "Scout Mode" comment), so there is no way
for this repo's Scout Mode to scan `bench_vectors` server-side. `head_to_head.py`
pulls the whole corpus into the Python client and re-sends it as a query
parameter on every single Scout call. At 100k x dim=768 scale that
string would be hundreds of megabytes, sent over the wire per query,
impractical for a benchmark meant to actually finish. 5000 x dim=128 keeps
the whole run under two seconds while still producing a clear, real
latency/recall gap.

The native-exact-scan arm has no such constraint (it re-reads the
`VECTOR(n)` column from the server on every query, with only the
client-side ranking layered on top), so if you only care
about that arm, `--n` can go much higher. `bench/vector_type_head_to_head.py`
(below) also scans server-side throughout and isn't bound by this limit
either.

## Scaling notes

Scout Mode's brute-force fitness (`min over corpus of ||candidate - v||^2`)
is O(N x D) per evaluation. The SFS core evaluates fitness well beyond a
flat population_size x iterations product (diffusion offspring plus
per-generation update passes each add more), so a population=50,
iterations=8 run makes on the order of ~2500 evaluations per query, not
400. The exact multiplier depends on the SFS core's own diffusion and
update schedule; the ~2500 order of magnitude is what to expect at
these defaults.
Real measured output from `bench/scale_sweep.sh 127.0.0.1
3306 <password>` against this project's Docker demo container
(dim=128, 5 queries averaged per N, every row measured, none
extrapolated):

| N (stored vectors) | Scout time per query | Scout recall (of top-50) |
| --- | --- | --- |
| 500 | 23.8 ms | 40.8 / 50 |
| 1,000 | 39.8 ms | 30.2 / 50 |
| 2,000 | 64.3 ms | 12.4 / 50 |
| 5,000 (default) | 165.5 ms | 5.6 / 50 |
| 10,000 | 392.6 ms | 6.4 / 50 |

Latency scales roughly linearly with N, matching the O(N x D) cost model.
Recall drops sharply as N grows past a couple thousand points (more points
crowd the same 50 clusters, so a fixed `population_size=50` samples a
shrinking fraction of the corpus), then ticks back up slightly at
N=10,000 -- that's the population-vs-corpus-size interaction, not
measurement noise. If you need recall to keep pace with a larger N, raise
`--top-k` (SFS `population_size`) along with it.

This table is Scout-only: it was measured against a Docker demo
container whose major predates any native-`VECTOR(n)` support, so
there's no comparable native row to pair with it in
this table. The native arm (see "What
you should see" above) is a server-side column read plus client-side
ranking and is effectively
N-independent by comparison, at whatever N your MySQL 9.7/26.7 server
can
hold; that section's own 5000-row measurement is the reference point for
it, not this table. For now, Scout Mode is best applied to curated
sub-corpora where diversity matters more than scan throughput.

## Tuning

`head_to_head.py` exposes a few knobs:

```
--n-queries     number of queries to average (default 5)
--top-k         #results per method, also SFS population_size (50)
--sfs-iter      SFS generations (default 8)
--sfs-mdn       diffusion factor (default 2)
--seed          query-selection RNG seed
```

`data_gen.py` exposes the dataset shape:

```
--n                  total points (default 5000)
--dim                vector dimension (default 128)
--clusters           number of Gaussian islands (default 50)
--sigma              intra-cluster std (default 0.05)
--with-native-vector add emb_vec VECTOR(dim) (MySQL 9.7/26.7; self-skips on 8.4)
--batch-size         rows per executemany() batch (default 500)
```

`bench/scale_sweep.sh [host] [port] [password]` runs `head_to_head.py
--quiet` across N = 500/1000/2000/5000/10000 (smaller than the 500-50000
range a large-corpus sweep would use, same reasoning as above).

## Portable TEXT vs native VECTOR(n) at scale

A second, unrelated benchmark: MySQL's built-in `VECTOR(n)` type vs. this
repo's own portable TEXT/JSON-array-string convention: storage size,
bulk-load throughput, and search latency, at `data_gen.py`'s real scale.
Distinct from the native-scan-vs-Scout comparison above. MySQL has no
way to define a custom `fractal_vector` SQL type (no
`CREATE TYPE`/type-modifier mechanism exists here at all), so this compares
the two storage shapes that actually exist here. Requires MySQL
9.7/26.7 for
the native arm (8.4 LTS has no `VECTOR` type).

```bash
make bench-vector BENCH_ARGS="--host 127.0.0.1 --password <root password>"
```

Or run the two steps directly:

```bash
python3 bench/data_gen.py --host 127.0.0.1 --password <root password> \
    --with-native-vector   # adds bench_vectors.emb_vec, if not already present
python3 bench/vector_type_head_to_head.py --host 127.0.0.1 --password <root password>
```

Real measured output (5000 rows, dim=128, measured on an earlier
version of this benchmark -- representative, not re-measured on
MySQL):

```
vector_type_head_to_head: 5000 rows, dim=128, native VECTOR(n)=yes

-- (a) storage size (OCTET_LENGTH, avg over up to 200 sampled rows) --
  VECTOR(n)     : 512 bytes  (fixed at 4 bytes/dim, float32)
  TEXT (JSON)   : 1218 bytes
  ratio         : 2.38x

-- (b) bulk load throughput (500 rows, dim=128, batched INSERT) --
  TEXT      : 0.22s (2235 rows/s)
  VECTOR(n) : 0.11s (4507 rows/s)

-- (c) fractal_search_trajectory latency: TEXT vs VECTOR(n) column --
  TEXT      : 139.2 ms avg over 5 queries (min 132.0, max 148.6)
  VECTOR(n) : 208.1 ms avg over 5 queries (min 194.3, max 216.1)
```

**Read this honestly, it isn't a clean sweep for either column type.**
`VECTOR(n)` is smaller on disk (fixed 4 bytes/dim, no storage-compression
path either side, so this ratio is architecturally fixed, not
data-dependent) and loads faster. But it was *slower* on sub-benchmark (c) in this run: the
underlying `fractal_search_trajectory`/`_telemetry`/`_hybrid_clinical_search`/
`_cross_modal_search` family reads a `VECTOR(n)` column through
`VECTOR_TO_STRING()` first (`_fractalsql_scan_corpus`,
`sql/install_udf.sql`) to get it into this
repo's own vector-text grammar, and that per-row conversion step costs more
than reading a plain `TEXT` column directly costs, in this measurement.
Judge for your own workload; don't assume `VECTOR(n)` wins on latency just
because it wins on storage size.

### A real bug this benchmark found (fixed at the source)

While writing sub-benchmark (c), every `fractal_search_trajectory` call
against the full 5000-row corpus (dim=128, ~6MB of vector text) silently
returned `[]`, zero results, **no error**. Root cause, confirmed directly:
`_fractalsql_scan_corpus` and `fractal_hybrid_clinical_search`
(`sql/install_udf.sql`) each build their corpus via `GROUP_CONCAT()`
without first raising the session's `group_concat_max_len`. MySQL's
default is 1024 bytes, low enough that this corpus size blows past it
immediately, and past that, `GROUP_CONCAT` silently *truncates* (warning
1260, "Row ... was cut by GROUP_CONCAT()", not an error), producing
invalid JSON that `fractal_search` then treats as an empty corpus. This
affected `fractal_search_telemetry`, `fractal_hybrid_clinical_search`,
`fractal_search_trajectory`, and `fractal_cross_modal_search` alike, at
any table whose combined vector text crossed that limit, a few hundred
rows at dim=128 was enough.

This is fixed at the source: both procedures raise
`SESSION group_concat_max_len` to 1 GiB before their `GROUP_CONCAT`
call and restore the session's prior value immediately after (see
`sql/install_udf.sql`'s comment on `_fractalsql_scan_corpus`, right
above the fix, for the full account).
`vector_type_head_to_head.py`'s own `SET SESSION group_concat_max_len`
call is redundant with the upstream fix but is harmless and
left in place as defense-in-depth for anyone running this script
against an older, unpatched build.

`vector_type_head_to_head.py`'s own knobs:

```
--load-n           row count for the load-throughput sub-benchmark
                    (default 2000, smaller than the full corpus,
                    this arm is O(n) by design so a subset is
                    representative)
--search-queries    queries to average for the latency sub-benchmark
                    (default 10)
```

### Sub-benchmark (d), peak RSS: not included

A fourth sub-benchmark reading `/proc/<pid>/status` around a
full-corpus scan, a regression tripwire for per-row memory actually
being freed as the scan goes, needs a one-process-per-connection
model to isolate a specific connection's RSS delta. mysqld's threading
model is the opposite: one shared multithreaded `mysqld` process
serves every connection at once, so there is no per-connection process
to read an isolated RSS delta from. A whole-process reading during this
benchmark's scan would be contaminated by whatever else that shared
server is doing for other connections at the same moment, and wouldn't
actually isolate the thing (d) is meant to test. Dropped rather than
faked; if you need memory-bound verification for the
native-`VECTOR(n)`/TEXT scan paths, a real profiler attached to the
`mysqld` process is the honest tool for that, not this benchmark.
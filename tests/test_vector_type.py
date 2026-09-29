#!/usr/bin/env python3
"""tests/test_vector_type.py: MySQL's NATIVE VECTOR column type
interop with this repo's portable fractal_vector JSON-array-string
convention.

MySQL has no
CREATE TYPE / type-modifier mechanism at all -- there is no custom type here.
What MySQL DOES have, from 9.0 on (community edition, verified live on
both 9.7 LTS and 26.7), is its OWN built-in
VECTOR(n) column type + STRING_TO_VECTOR()/VECTOR_TO_STRING() (synonyms
TO_VECTOR()/FROM_VECTOR()), which
this repo's fractal_vector_* functions interoperate with via a shared
bracket-comma text grammar (verified, not assumed -- see
sql/install_udf.sql's own comment near CREATE FUNCTION fractal_vector_dims,
and this file's own scenarios below, each re-derived against the MySQL
9.7/26.7 grammar before being written). On 8.4 LTS, none of this exists --
the server has no VECTOR type at all; every fractal_vector_* function
still works unchanged on the portable TEXT/JSON-string path (covered by
build_test.sh's gate 22, not here).

What MySQL's native tier does NOT add (as of 9.7 LTS and 26.7
Community, verified live -- every candidate name was probed):
no distance function of ANY name (DISTANCE()/COSINE_DISTANCE()/
VECTOR_DISTANCE() all fail with FUNCTION ... does not exist) and no
ANN vector indexes -- these are HeatWave-only features -- see
src/fractalsql_vector.c's header. That is precisely why this repo's
fractal_vector_cosine_distance() (the portable path) is the only
in-server distance math on the box, and why the scenarios below stick
to the exact-match/text-interop surface, never an in-server distance.

Scenarios:
  1. Native round trip: STRING_TO_VECTOR(fractal_vector_normalize(...))
     into a VECTOR(n) column, VECTOR_TO_STRING() back out, matches the
     portable path's own output.
  2. Cross-path distance agreement: cosine distance computed in the
     CLIENT from VECTOR_TO_STRING(embedding) (the only way to get
     distance math off a native column on Community) agrees with
     fractal_vector_cosine_distance() on the same text (both paths,
     same underlying float32 storage).
  3. Native dimension enforcement: MySQL itself (not this repo's SQL)
     rejects an INSERT whose vector literal doesn't match the column's
     declared VECTOR(n) width -- no code in this repo has to detect
     this; the server enforces the declared width itself.
  4. Vectorizer auto-detection: fractal_vectorizer_create() against a
     VECTOR(n) embedding_col sets fractal_vectorizers.embedding_is_
     vector_type, and fractal_vectorizer_process_queue() writes back
     through STRING_TO_VECTOR() automatically -- exercised end-to-end
     against the mock embeddings endpoint, not just asserting the flag.

Skip-safe: exits 0 with SKIP if the mysql connector is missing, no DB
is reachable, or VECTOR(n) isn't supported by the connected server
(8.4 LTS -- detected by attempting a throwaway VECTOR(1) column, not by
parsing VERSION() text, since that's what actually matters).
Scenario 4 additionally skips (not fails) if the reasoning plugin
isn't present on this host.

Usage:
    python3 tests/test_vector_type.py
"""
import os
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str, MutableMockLLMServer


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def _cosine(a, b):
    """Client-side cosine DISTANCE (1 - cos), the reference the UDF's
    result is checked against in scenario 2."""
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    return 1.0 - dot / (na * nb)


def native_vector_supported(cur):
    try:
        cur.execute("DROP TABLE IF EXISTS _fv_probe")
        cur.execute("CREATE TABLE _fv_probe (v VECTOR(1) NOT NULL)")
        cur.execute("DROP TABLE _fv_probe")
        return True
    except Exception:
        return False


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    cur = conn.cursor()
    if not native_vector_supported(cur):
        print("SKIP: connected server has no native VECTOR(n) support "
              "(MySQL 8.4 LTS) -- fractal_vector_* still works unchanged "
              "on the portable TEXT/JSON path, see build_test.sh gate 22")
        return 0

    passed = 0

    # ---- Scenario 1: native round trip vs. the portable path --------
    cur.execute("DROP TABLE IF EXISTS _fv_native")
    cur.execute("CREATE TABLE _fv_native (id INT PRIMARY KEY, embedding VECTOR(3) NOT NULL)")
    cur.execute(
        "INSERT INTO _fv_native VALUES (1, STRING_TO_VECTOR(fractal_vector_normalize('[3,4,0]')))")
    cur.execute("SELECT VECTOR_TO_STRING(embedding) FROM _fv_native WHERE id = 1")
    native_text = to_str(cur.fetchone()[0])
    cur.execute("SELECT fractal_vector_normalize('[3,4,0]')")
    portable_text = to_str(cur.fetchone()[0])
    native_vals = [float(x) for x in native_text.strip("[]").split(",")]
    portable_vals = [float(x) for x in portable_text.strip("[]").split(",")]
    if len(native_vals) != 3 or any(abs(a - b) > 1e-3 for a, b in zip(native_vals, portable_vals)):
        fail(f"[native round trip] native={native_vals!r} != portable={portable_vals!r}")
    print(f"OK: [native round trip] STRING_TO_VECTOR/VECTOR_TO_STRING matches the portable "
          f"path: {native_vals!r}")
    passed += 1

    # ---- Scenario 2: cross-path distance agreement ------------------
    # Community MySQL has no in-server distance function (see this
    # file's docstring), so the native column's distance comes out via
    # VECTOR_TO_STRING() and is computed in this client -- then compared
    # against the UDF's math on the same text.
    cur.execute(
        "SELECT VECTOR_TO_STRING(embedding) FROM _fv_native WHERE id = 1")
    native_text = to_str(cur.fetchone()[0])
    native_vals = [float(x) for x in native_text.strip("[]").split(",")]
    client_dist = _cosine(native_vals, [1.0, 0.0, 0.0])
    cur.execute(
        "SELECT fractal_vector_cosine_distance(VECTOR_TO_STRING(embedding), '[1,0,0]') "
        "FROM _fv_native WHERE id = 1")
    portable_dist = float(cur.fetchone()[0])
    if abs(client_dist - portable_dist) > 1e-3:
        fail(f"[cross-path distance] client-computed={client_dist} != "
             f"fractal_vector_cosine_distance={portable_dist}")
    print(f"OK: [cross-path distance] client-computed={client_dist:.6f} == "
          f"portable={portable_dist:.6f}")
    passed += 1
    cur.execute("DROP TABLE IF EXISTS _fv_native")

    # ---- Scenario 3: native dimension enforcement --------------------
    cur.execute("DROP TABLE IF EXISTS _fv_dim")
    cur.execute("CREATE TABLE _fv_dim (id INT PRIMARY KEY, embedding VECTOR(3) NOT NULL)")
    try:
        cur.execute("INSERT INTO _fv_dim VALUES (1, STRING_TO_VECTOR('[1,2]'))")
        cur.execute("DROP TABLE IF EXISTS _fv_dim")
        fail("[dimension enforcement] expected MySQL to reject a dim-2 "
             "literal into a VECTOR(3) column, insert succeeded")
    except Exception as e:
        print(f"OK: [dimension enforcement] MySQL itself rejected the "
              f"mismatched insert: {e}")
        passed += 1
    cur.execute("DROP TABLE IF EXISTS _fv_dim")

    # ---- Scenario 4: vectorizer auto-detects a native VECTOR(n) col -
    # fractal_vectorizer_create hands back its CREATE TRIGGER DDL as OUT
    # params (MySQL error 1295 -- CREATE TRIGGER is not a PREPARE target,
    # so this procedure cannot run the DDL inline),
    # so this scenario must execute the two returned statements before
    # the enqueue triggers exist. MySQL does not return OUT params as a
    # result set -- CALL-then-SELECT-@var (build_test.sh's proven
    # pattern) reads them back as session variables.
    if not reasoning_available():
        print("SKIP: [vectorizer auto-detect] reasoning plugin not found on this host")
    else:
        mock_port = int(os.environ.get("FRACTALSQL_MOCK_PORT", "18080"))
        vec = [0.1, 0.2, 0.3]
        try:
            with MutableMockLLMServer(mock_port) as mock:
                mock.set_embed_vector(vec)
                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_fv_vec_auto'")
                cur.execute("DROP TABLE IF EXISTS _fv_vec_auto")
                cur.execute("""
                    CREATE TABLE _fv_vec_auto (
                        id BIGINT PRIMARY KEY AUTO_INCREMENT,
                        body TEXT NOT NULL,
                        embedding VECTOR(3)
                    )
                """)
                cur.execute(
                    "CALL fractal_vectorizer_create('_fv_vec_auto', 'body', 'embedding', "
                    "NULL, @vzid, @vins_trg, @vupd_trg)")
                cur.execute("SELECT @vzid, @vins_trg, @vupd_trg")
                vzid, ins_trg_sql, upd_trg_sql = cur.fetchone()
                if not vzid or not ins_trg_sql or not upd_trg_sql:
                    fail(f"[vectorizer auto-detect] create returned vzid={vzid!r} "
                         f"ins_trg={ins_trg_sql!r} upd_trg={upd_trg_sql!r}")
                cur.execute(ins_trg_sql)
                cur.execute(upd_trg_sql)

                cur.execute(
                    "SELECT embedding_is_vector_type FROM fractal_vectorizers WHERE id = %s",
                    (vzid,))
                is_vec = cur.fetchone()[0]
                if not is_vec:
                    fail("[vectorizer auto-detect] embedding_is_vector_type was not "
                         "set TRUE for a VECTOR(3) embedding_col")

                cur.execute("INSERT INTO _fv_vec_auto (body) VALUES ('a')")
                cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
                n = cur.fetchone()[0]
                if n != 1:
                    fail(f"[vectorizer auto-detect] expected 1 row processed, got {n}")

                cur.execute("SELECT VECTOR_TO_STRING(embedding) FROM _fv_vec_auto WHERE id = 1")
                got_text = to_str(cur.fetchone()[0])
                got = [float(x) for x in got_text.strip("[]").split(",")]
                if any(abs(a - b) > 1e-3 for a, b in zip(got, vec)):
                    fail(f"[vectorizer auto-detect] wrote back {got!r}, expected {vec!r}")

                print(f"OK: [vectorizer auto-detect] embedding_is_vector_type set "
                      f"automatically, process_queue wrote back through STRING_TO_VECTOR() "
                      f"correctly: {got!r}")
                passed += 1

                cur.execute("DROP TABLE IF EXISTS _fv_vec_auto")
                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_fv_vec_auto'")
        except OSError as e:
            print(f"SKIP: [vectorizer auto-detect] could not bind mock port "
                  f"{mock_port}: {e}")

    print(f"\ntest_vector_type: PASS ({passed} scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
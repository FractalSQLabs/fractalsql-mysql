-- demo/demo-vectorizer.sql
--
-- Runnable walkthrough of fractal_vectorizer_create() /
-- fractal_vectorizer_process_queue() / the fractal_vectorizer_status
-- view. See docs/vectorizer-setup.md for the full API reference, the
-- BYO-scheduler options, and open questions (chunking, cost controls).
--
-- Prerequisites: UDFs registered, reasoning AND embedding configured
-- as process environment variables in mysqld's own environment
-- BEFORE it starts (mysqld has no sysvar/my.cnf config surface for
-- any of this; see build_test.sh's mysql_setup for the export pattern):
--   FRACTALSQL_REASONING_PLUGIN = /usr/lib64/mysql/plugin/fractalsql-reasoning-http.so
--   FRACTALSQL_HTTP_URL         = http://127.0.0.1:11434/v1/chat/completions
--   FRACTALSQL_HTTP_MODEL       = gpt-oss:20b
--   FRACTALSQL_HTTP_EMBED_URL   = http://127.0.0.1:11434/v1/embeddings
--   FRACTALSQL_HTTP_EMBED_MODEL = nomic-embed-text
-- Local Ollama example pairing a chat model with a real embedding
-- model from the same host (never reuse the chat model for embeddings,
-- a purpose-trained model matters):
--
--   ollama pull gpt-oss:20b
--   ollama pull nomic-embed-text
--
-- Confirm before running this script. Unlike fractal_reason(),
-- fractal_embed() just returns a vector (a fractal_vector JSON-array-
-- string), not a reply, so "it works" means "this returns a non-NULL
-- array, not an error":
--   SELECT fractal_embed(CONNECTION_ID(), 'connection test');
--
-- Safe to re-run: the schema is dropped and recreated at the top.

DROP TABLE IF EXISTS docs;

CREATE TABLE docs (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    body      TEXT NOT NULL,
    embedding JSON
) COMMENT = 'Toy document store, one row per short passage';

-- === Section 1: some rows BEFORE the vectorizer exists ===
-- fractal_vectorizer_create() backfills existing rows automatically,
-- these three will be queued the moment it runs, no separate step needed.
INSERT INTO docs (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside MySQL.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.'),
    ('fractal_text_to_sql never executes what it generates, that is always separate.');

SELECT id, body FROM docs ORDER BY id;

-- === Section 2: create the vectorizer ===
-- fractal_vectorizer_create is a PROCEDURE (trailing OUT p_id plus,
-- on MySQL, the two trigger-DDL OUT params: error 1295 -- CREATE
-- TRIGGER is not a PREPARE target -- means the procedure returns the
-- DDL instead of running it; in production run the two returned
-- statements as-is. This scripted demo pins the vectorizer id to 1
-- (full-table DELETE + AUTO_INCREMENT reset below) so it can install
-- the equivalent triggers literally).
-- Clear any leftover catalog row from a previous run first (DROP TABLE
-- docs above destroyed the trigger-backed table itself, but not
-- fractal_vectorizer_create()'s own duplicate-source_table guard).
DELETE FROM fractal_vectorizers WHERE source_table = 'docs';
ALTER TABLE fractal_vectorizers AUTO_INCREMENT = 1;   -- demo determinism: pins @vzid = 1 so the literal trigger DDL below matches it
CALL fractal_vectorizer_create('docs', 'body', 'embedding', NULL, @vzid, @ins_trg_sql, @upd_trg_sql);
SELECT @vzid AS vectorizer_id, @ins_trg_sql AS ins_trigger_sql, @upd_trg_sql AS upd_trigger_sql;
DROP TRIGGER IF EXISTS `_fsql_vec_1_ins`;
DROP TRIGGER IF EXISTS `_fsql_vec_1_upd`;
CREATE TRIGGER `_fsql_vec_1_ins` AFTER INSERT ON `docs` FOR EACH ROW CALL _fractalsql_vectorizer_enqueue(1, NEW.`id`);
CREATE TRIGGER `_fsql_vec_1_upd` AFTER UPDATE ON `docs` FOR EACH ROW CALL _fractalsql_vectorizer_enqueue_changed(1, NEW.`id`, OLD.`body`, NEW.`body`);

-- Backfilled queue (all 3 rows above, none had an embedding yet).
-- fractal_vectorizer_queue is a plain table, not a function, so
-- GROUP BY works directly.
SELECT status, COUNT(*) FROM fractal_vectorizer_queue GROUP BY status;

-- === Section 3: a NEW row after the vectorizer exists ===
-- The trigger queues it automatically, no manual step. A MySQL UDF
-- cannot itself be a trigger body, so a MySQL TRIGGER whose body
-- CALLs a plain procedure does the job instead, which is exactly what
-- fractal_vectorizer_create() generates and installs for
-- you (sql/install_udf.sql):
--   CREATE TRIGGER <source_table>_fsql_vec_ins AFTER INSERT ON docs
--   FOR EACH ROW CALL _fractalsql_vectorizer_enqueue(<vectorizer_id>, NEW.id);
INSERT INTO docs (body) VALUES
    ('Sniper Search refines a query point; Scout Mode returns a diverse population instead.');

SELECT status, COUNT(*) FROM fractal_vectorizer_queue GROUP BY status;

-- === Section 4: process the queue ===
-- This is the one function you put on a schedule (the MySQL Event
-- Scheduler, OS cron, Windows Task Scheduler, your own app; see
-- docs/vectorizer-setup.md for the BYO-scheduler options). Running it
-- manually here for the demo:
CALL fractal_vectorizer_process_queue(100, 600);

-- === Section 5: check the results ===
SELECT id, body, embedding IS NOT NULL AS has_embedding,
       CASE WHEN embedding IS NOT NULL THEN JSON_LENGTH(embedding) END AS dim
FROM docs
ORDER BY id;

-- Status view: what fractal_vectorizer_process_queue() actually did:
SELECT vectorizer_id, source_table, status, n, last_error
FROM fractal_vectorizer_status
ORDER BY status;

-- === Section 6: edit a row, watch it get re-queued ===
UPDATE docs SET body = CONCAT(body, ' (edited)') WHERE id = 1;
SELECT status, COUNT(*) FROM fractal_vectorizer_queue GROUP BY status;
CALL fractal_vectorizer_process_queue(100, 600);
SELECT vectorizer_id, status, n FROM fractal_vectorizer_status ORDER BY status;

-- Next: docs/vectorizer-setup.md for the BYO-scheduler examples;
-- nothing here ran fractal_vectorizer_process_queue() on a schedule,
-- this demo called it manually once per section.
--
-- Clean up (fractal_vectorizers has no FK back to docs, so this order
-- matters: delete the vectorizer row first, its queue rows cascade
-- automatically, then drop the table):
--   DELETE FROM fractal_vectorizers WHERE source_table = 'docs';
--   DROP TABLE docs;

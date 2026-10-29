import assert from "node:assert/strict";
import { test } from "node:test";

import pg from "pg";

const url = process.env.POSTGRES_URL;
const enabled = url !== undefined && url.trim() !== "";

const table = `
CREATE TABLE IF NOT EXISTS sol_jobs (
  id SERIAL PRIMARY KEY,
  workspace TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INT NOT NULL DEFAULT 0,
  run_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error TEXT,
  dedupe_key TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (workspace, run_at) WHERE status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
  ON sol_jobs (workspace, kind, dedupe_key) WHERE dedupe_key IS NOT NULL;
`;

test("local TypeScript task host acknowledges a sol_jobs row", { skip: !enabled }, async () => {
  const { enqueue } = await import("@sol-fab/jobs");
  const { runLocalTasks } = await import("../dist/local.js");
  const pool = new pg.Pool({ connectionString: url, max: 1 });
  try {
    await pool.query(table);
    await pool.query("DELETE FROM sol_jobs WHERE workspace = 'ts-local-test'");
    const envelope = {
      task_id: "ts-local-1",
      kind: "send_welcome",
      payload: JSON.stringify({ kind: "send_welcome", user_id: "u-1" }),
      idempotency_key: "ts-local-1",
    };
    const contract = {
      workspace: "ts-local-test",
      kinds: ["send_welcome"],
      kind: (task) => task.kind,
      encode: (task) => JSON.stringify(task),
      decode: (payload) => JSON.parse(payload),
      handle: async () => {},
    };
    await enqueue(pool, contract, envelope, { dedupeKey: envelope.idempotency_key });
    await enqueue(pool, contract, envelope, { dedupeKey: envelope.idempotency_key });
    const count = await pool.query(
      "SELECT count(*)::int AS n FROM sol_jobs WHERE workspace = 'ts-local-test'",
    );
    assert.equal(count.rows[0].n, 1);
    await runLocalTasks({ pool, workspace: "ts-local-test", maxJobs: 1 });
    const row = await pool.query(
      "SELECT status, attempts FROM sol_jobs WHERE workspace = 'ts-local-test'",
    );
    assert.deepEqual(row.rows[0], { status: "completed", attempts: 1 });
  } finally {
    await pool.end();
  }
});

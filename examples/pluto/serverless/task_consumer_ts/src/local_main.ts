/** Local durable-task consumer entrypoint.
 *
 * The task envelope and handler are shared with the Lambda and Pub/Sub
 * adapters. @sol-fab/jobs owns the Postgres queue semantics.
 */
import pg from "pg";

import { runLocalTasks } from "./local.js";

async function main(): Promise<void> {
  const url = process.env.POSTGRES_URL;
  if (url === undefined || url.trim() === "") {
    throw new Error("POSTGRES_URL is required for the local task consumer");
  }
  const maxJobsRaw = process.env.SOL_TASK_MAX_JOBS;
  const maxJobs = maxJobsRaw === undefined ? undefined : Number(maxJobsRaw);
  if (maxJobs !== undefined && (!Number.isInteger(maxJobs) || maxJobs < 0)) {
    throw new Error("SOL_TASK_MAX_JOBS must be a non-negative integer");
  }
  const pool = new pg.Pool({ connectionString: url, max: 1 });
  try {
    await runLocalTasks({
      pool,
      workspace: process.env.SOL_TASK_WORKSPACE ?? "pluto",
      ...(maxJobs === undefined ? {} : { maxJobs }),
    });
  } finally {
    await pool.end();
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});

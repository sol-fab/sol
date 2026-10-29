/** Local Postgres task host built on the published @sol-fab/jobs queue.
 *
 * This is the TypeScript host for the same shared task envelope as the SQS and
 * Pub/Sub adapters. It does not reimplement leasing or retry: @sol-fab/jobs owns
 * the sol_jobs claim/lease/backoff loop, and this module only maps the shared
 * task contract onto it.
 */
import type { Pool } from "pg";

import { handleEnvelope, parseEnvelope, type TaskEnvelope } from "./task.js";

export interface LocalTaskOptions {
  pool: Pool;
  workspace?: string;
  maxJobs?: number;
  signal?: AbortSignal;
}

async function runWithJobs(options: LocalTaskOptions): Promise<void> {
  const { runJobs } = await import("@sol-fab/jobs");
  const runOptions = {
    pool: options.pool,
    contract: {
      workspace: options.workspace ?? "pluto",
      kinds: ["send_welcome"],
      kind: (envelope: TaskEnvelope) => envelope.kind,
      encode: (envelope: TaskEnvelope) => JSON.stringify(envelope),
      decode: (payload: string) => {
        const parsed = parseEnvelope(payload);
        if (!parsed.ok) {
          throw new Error(parsed.error);
        }
        return parsed.envelope;
      },
      handle: async (envelope: TaskEnvelope) => {
        if (handleEnvelope(envelope) === "retry") {
          throw new Error("task requested retry");
        }
      },
    },
    ...(options.maxJobs === undefined ? {} : { maxJobs: options.maxJobs }),
    ...(options.signal === undefined ? {} : { signal: options.signal }),
  };
  const error = await runJobs(runOptions);
  if (error !== undefined) {
    throw new Error(`local task runner: ${error.message}`);
  }
}

/** Run the shared task handler until the queue is stopped or [maxJobs] terminal
 * outcomes have been observed. The caller owns the Postgres pool. */
export async function runLocalTasks(options: LocalTaskOptions): Promise<void> {
  await runWithJobs(options);
}

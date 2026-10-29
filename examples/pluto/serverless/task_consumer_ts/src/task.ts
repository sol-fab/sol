/** Shared task envelope and outcome boundary for the demo adapters.
 *
 * This module is deliberately small and demo-local: the published TypeScript
 * framework has no `@sol-fab/task` package yet. It is shared by the AWS SQS and
 * GCP Pub/Sub adapters so retry/ack/malformed behavior does not drift between
 * the two provider paths.
 */
export interface TaskEnvelope {
  task_id: string;
  kind: string;
  payload: string;
  idempotency_key?: string;
}

export type ParseResult =
  | { ok: true; envelope: TaskEnvelope }
  | { ok: false; error: string };

export type Outcome = "ack" | "retry";

export function parseEnvelope(raw: string): ParseResult {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (error) {
    return { ok: false, error: `task envelope is not JSON: ${String(error)}` };
  }
  if (value === null || typeof value !== "object") {
    return { ok: false, error: "task envelope must be a JSON object" };
  }
  const envelope = value as Partial<TaskEnvelope>;
  if (
    typeof envelope.task_id !== "string" ||
    envelope.task_id.length === 0 ||
    typeof envelope.kind !== "string" ||
    envelope.kind.length === 0 ||
    typeof envelope.payload !== "string"
  ) {
    return { ok: false, error: "task envelope is missing task_id, kind or payload" };
  }
  if (envelope.payload !== "fail") {
    try {
      const payload = JSON.parse(envelope.payload) as { kind?: unknown; user_id?: unknown };
      if (
        payload === null ||
        typeof payload !== "object" ||
        payload.kind !== "send_welcome" ||
        typeof payload.user_id !== "string"
      ) {
        return { ok: false, error: "unsupported send_welcome payload" };
      }
    } catch (error) {
      return { ok: false, error: `task payload is not JSON: ${String(error)}` };
    }
  }
  return {
    ok: true,
    envelope: {
      task_id: envelope.task_id,
      kind: envelope.kind,
      payload: envelope.payload,
      idempotency_key:
        typeof envelope.idempotency_key === "string" ? envelope.idempotency_key : undefined,
    },
  };
}

/** The demo's handler has no external side effect; it logs the stable identity
 * so redelivery is observable and returns Retry only for the synthetic `fail`
 * payload. Application idempotency remains the handler's responsibility. */
export function handleEnvelope(envelope: TaskEnvelope): Outcome {
  console.log(
    `task_consumer task_id=${envelope.task_id} kind=${envelope.kind} ` +
      `idempotency_key=${envelope.idempotency_key ?? "-"}`,
  );
  return envelope.payload === "fail" ? "retry" : "ack";
}

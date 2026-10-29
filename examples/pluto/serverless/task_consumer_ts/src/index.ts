/** An SQS task consumer deployed through Sol's task lifecycle.
 *
 * The OCaml side uses `sol-task.lambda`; the published TypeScript framework has
 * no task runtime yet, so this demo implements the provider boundary directly:
 * parse the shared task envelope, run the handler, and report only failed SQS
 * records. It is deliberately dependency-free and logs the stable task_id.
 */
interface SqsRecord {
  messageId: string;
  body: string;
}

interface SqsEvent {
  Records?: SqsRecord[];
}

interface TaskEnvelope {
  task_id?: string;
  kind?: string;
  payload?: string;
  idempotency_key?: string;
}

interface BatchFailure {
  itemIdentifier: string;
}

export async function handler(event: SqsEvent): Promise<{ batchItemFailures: BatchFailure[] }> {
  const failures: BatchFailure[] = [];
  for (const record of event.Records ?? []) {
    try {
      const envelope = JSON.parse(record.body) as TaskEnvelope;
      if (
        typeof envelope.task_id !== "string" ||
        typeof envelope.kind !== "string" ||
        typeof envelope.payload !== "string"
      ) {
        throw new Error("task envelope is missing task_id, kind or payload");
      }
      console.log(
        `task_consumer task_id=${envelope.task_id} kind=${envelope.kind} ` +
          `idempotency_key=${envelope.idempotency_key ?? "-"}`,
      );
      if (envelope.payload === "fail") {
        failures.push({ itemIdentifier: record.messageId });
      }
    } catch (error) {
      console.error(`task_consumer malformed record ${record.messageId}: ${String(error)}`);
      failures.push({ itemIdentifier: record.messageId });
    }
  }
  return { batchItemFailures: failures };
}

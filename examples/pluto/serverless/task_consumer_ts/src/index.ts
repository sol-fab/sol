/** AWS SQS task consumer. */
import { handleEnvelope, parseEnvelope } from "./task.js";

interface SqsRecord {
  messageId: string;
  body: string;
}

interface SqsEvent {
  Records?: SqsRecord[];
}

interface BatchFailure {
  itemIdentifier: string;
}

export async function handler(event: SqsEvent): Promise<{ batchItemFailures: BatchFailure[] }> {
  const failures: BatchFailure[] = [];
  for (const record of event.Records ?? []) {
    const parsed = parseEnvelope(record.body);
    if (!parsed.ok) {
      console.error(`task_consumer malformed record ${record.messageId}: ${parsed.error}`);
      failures.push({ itemIdentifier: record.messageId });
      continue;
    }
    if (handleEnvelope(parsed.envelope) === "retry") {
      failures.push({ itemIdentifier: record.messageId });
    }
  }
  return { batchItemFailures: failures };
}

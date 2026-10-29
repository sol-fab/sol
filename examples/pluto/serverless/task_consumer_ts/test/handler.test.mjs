import assert from "node:assert/strict";
import { test } from "node:test";

import { handler } from "../dist/index.js";

test("acknowledges a well-formed task", async () => {
  const result = await handler({
    Records: [
      {
        messageId: "m-ack",
        body: JSON.stringify({
          task_id: "task-ack",
          kind: "send_welcome",
          payload: '{"kind":"send_welcome","user_id":"u-1"}',
          idempotency_key: "welcome-u-1",
        }),
      },
    ],
  });
  assert.deepEqual(result, { batchItemFailures: [] });
});

test("reports an explicit fail without hiding the rest of the batch", async () => {
  const result = await handler({
    Records: [
      {
        messageId: "m-ack",
        body: JSON.stringify({
          task_id: "task-ack",
          kind: "send_welcome",
          payload: '{"kind":"send_welcome","user_id":"u-1"}',
        }),
      },
      {
        messageId: "m-fail",
        body: JSON.stringify({
          task_id: "task-fail",
          kind: "send_welcome",
          payload: "fail",
        }),
      },
    ],
  });
  assert.deepEqual(result, { batchItemFailures: [{ itemIdentifier: "m-fail" }] });
});

test("reports a malformed envelope for retry", async () => {
  const result = await handler({
    Records: [{ messageId: "m-bad", body: "not json" }],
  });
  assert.deepEqual(result, { batchItemFailures: [{ itemIdentifier: "m-bad" }] });
});

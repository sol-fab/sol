import assert from "node:assert/strict";
import { test } from "node:test";

import { handlePush } from "../dist/pubsub.js";

function push(body) {
  return {
    message: { data: Buffer.from(JSON.stringify(body), "utf8").toString("base64") },
  };
}

test("acknowledges a well-formed task", () => {
  const result = handlePush(
    JSON.stringify(
      push({
        task_id: "task-ack",
        kind: "send_welcome",
        payload: JSON.stringify({ kind: "send_welcome", user_id: "u-1" }),
      }),
    ),
  );
  assert.deepEqual(result, { status: 200, body: "" });
});

test("retries the synthetic failure", () => {
  const result = handlePush(
    JSON.stringify(push({ task_id: "task-fail", kind: "send_welcome", payload: "fail" })),
  );
  assert.equal(result.status, 500);
});

test("rejects malformed push data without retrying forever", () => {
  const result = handlePush(JSON.stringify({ message: {} }));
  assert.equal(result.status, 400);
});

test("rejects a malformed envelope", () => {
  const result = handlePush(JSON.stringify({ message: { data: Buffer.from("not-json").toString("base64") } }));
  assert.equal(result.status, 400);
});

test("rejects an unsupported task payload", () => {
  const result = handlePush(
    JSON.stringify({
      message: {
        data: Buffer.from(
          JSON.stringify({
            task_id: "task-bad",
            kind: "send_welcome",
            payload: "not-json",
          }),
        ).toString("base64"),
      },
    }),
  );
  assert.equal(result.status, 400);
});

test("duplicate delivery is processed again but remains safe", () => {
  const body = JSON.stringify(
    push({
      task_id: "task-dup",
      kind: "send_welcome",
      payload: JSON.stringify({ kind: "send_welcome", user_id: "u-1" }),
    }),
  );
  assert.equal(handlePush(body).status, 200);
  assert.equal(handlePush(body).status, 200);
});

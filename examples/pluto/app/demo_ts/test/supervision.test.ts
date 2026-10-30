import { test } from "node:test";
import assert from "node:assert/strict";
import * as service from "../order_svc/src/runner-supervision.js";
import * as worker from "../fulfillment_worker/src/runner-supervision.js";

const modules: ReadonlyArray<readonly [string, typeof service]> = [
  ["order service", service],
  ["fulfillment worker", worker],
];

for (const [name, module] of modules) {
  test(`${name}: a terminal runner failure shuts the lifecycle down once`, async () => {
    const calls: string[] = [];
    let shutdowns = 0;
    const supervisor = module.supervise((message) => calls.push(message));
    supervisor.attach({
      shutdown: async () => {
        shutdowns += 1;
      },
    });

    supervisor.report("outbox relay", { kind: "database", message: "connection refused" });
    await Promise.resolve();
    assert.match(supervisor.failure()?.message ?? "", /outbox relay stopped: connection refused/);

    supervisor.report("jobs runner", { kind: "database", message: "later failure" });
    await Promise.resolve();
    assert.equal(shutdowns, 1, "a second failure must not shut down twice");
    assert.match(supervisor.failure()?.message ?? "", /connection refused/);
    assert.equal(calls.length, 1);
  });

  test(`${name}: a failure before lifecycle registration still shuts down`, async () => {
    let shutdowns = 0;
    const supervisor = module.supervise(() => {});
    supervisor.report("outbox relay", { kind: "database", message: "early failure" });
    supervisor.attach({
      shutdown: async () => {
        shutdowns += 1;
      },
    });
    await Promise.resolve();
    assert.equal(shutdowns, 1);
    assert.match(supervisor.failure()?.message ?? "", /early failure/);
  });

  test(`${name}: a clean runner stop is not a failure`, async () => {
    const supervisor = module.supervise(() => {});
    await module.watch(Promise.resolve(undefined), "outbox relay", supervisor);
    assert.equal(supervisor.failure(), undefined);
  });


  test(`${name}: a rejected runner promise is reported as a crash`, async () => {
    const calls: string[] = [];
    let shutdowns = 0;
    const supervisor = module.supervise((message) => calls.push(message));
    supervisor.attach({
      shutdown: async () => {
        shutdowns += 1;
      },
    });

    await module.watch(
      Promise.reject(new Error("relay exploded")),
      "outbox relay",
      supervisor,
    );
    assert.match(supervisor.failure()?.message ?? "", /outbox relay stopped: Error: relay exploded/);
    assert.equal(shutdowns, 1);
    assert.equal(calls.length, 1);
  });

  test(`${name}: watch reports a terminal error`, async () => {
    const supervisor = module.supervise(() => {});
    await module.watch(
      Promise.resolve({ kind: "config", message: "bad contract" }),
      "outbox relay",
      supervisor,
    );
    assert.match(supervisor.failure()?.message ?? "", /bad contract/);
  });
}

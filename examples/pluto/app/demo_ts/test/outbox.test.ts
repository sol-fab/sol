import { test } from "node:test";
import assert from "node:assert/strict";
import { pending, pendingCount, runRelay, type Publication } from "@sol-fab/outbox";
import { makeDb } from "../fulfillment_worker/src/db.js";
import {
  enqueueOrderJob,
  INVENTORY_KIND,
  makeOrderJobs,
  WORKSPACE,
} from "../fulfillment_worker/src/jobs.js";
import { FULFILLED_KIND, publishFulfilled } from "../fulfillment_worker/src/outbox.js";
import { ORDER_PLACED_KIND, publishOrderPlaced } from "../order_svc/src/outbox.js";
import { fulfillOrder } from "../fulfillment_worker/src/fulfill.js";
import { applyMigrations } from "./migrations.js";
import type { OrderFulfilled } from "@demo-ts/contract";

const POSTGRES_URL = process.env.POSTGRES_URL;
const withDb = POSTGRES_URL ? test : test.skip;

const jobs = makeOrderJobs(() => {}, { markConfirmed: async () => {} });

function order(orderId: string): OrderFulfilled {
  return { order_id: orderId, item: "widget", quantity: 2, correlation_id: `corr-${orderId}` };
}

async function clean(db: Awaited<ReturnType<typeof makeDb>>, orderId: string): Promise<void> {
  await db.pool.query("DELETE FROM fulfilled_orders_ts WHERE order_id = $1", [orderId]);
  await db.pool.query("DELETE FROM order_confirmations_ts WHERE order_id = $1", [orderId]);
  await db.pool.query("DELETE FROM orders_ts WHERE order_id = $1", [orderId]);
  await db.pool.query("DELETE FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2", [
    WORKSPACE,
    orderId,
  ]);
  await db.pool.query("DELETE FROM sol_outbox WHERE aggregate_key = $1", [orderId]);
}

async function counts(db: Awaited<ReturnType<typeof makeDb>>, orderId: string) {
  const fulfilled = await db.pool.query(
    "SELECT count(*)::int AS n FROM fulfilled_orders_ts WHERE order_id = $1",
    [orderId],
  );
  const job = await db.pool.query(
    "SELECT count(*)::int AS n FROM sol_jobs WHERE workspace = $1 AND dedupe_key = $2",
    [WORKSPACE, orderId],
  );
  const outbox = await db.pool.query(
    "SELECT count(*)::int AS n FROM sol_outbox WHERE aggregate_key = $1",
    [orderId],
  );
  return { fulfilled: fulfilled.rows[0].n, job: job.rows[0].n, outbox: outbox.rows[0].n };
}

async function relayUntil(
  pool: Awaited<ReturnType<typeof makeDb>>["pool"],
  publish: (publication: Publication) => Promise<void>,
  done: () => boolean,
): Promise<Awaited<ReturnType<typeof runRelay>>> {
  const controller = new AbortController();
  return runRelay({
    pool,
    kinds: [FULFILLED_KIND],
    publish: async (publication) => {
      await publish(publication);
      if (done()) controller.abort();
    },
    signal: controller.signal,
    sleep: async () => {},
  });
}

withDb("the domain write, its job and its outbox intent commit in one transaction", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  try {
    await clean(db, "outbox-commit");
    await db.withTransaction(async (client) => {
      await fulfillOrder(db, client, order("outbox-commit"), jobs);
    });

    assert.deepEqual(await counts(db, "outbox-commit"), { fulfilled: 1, job: 1, outbox: 1 });
    assert.deepEqual(await pending(db.pool), [{ key: "outbox-commit", ord: 2 }]);
  } finally {
    await clean(db, "outbox-commit");
    await db.close();
  }
});

withDb("a failure after the writes rolls the domain row, the job and the intent back together", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  try {
    await clean(db, "outbox-rollback");
    await assert.rejects(
      () =>
        db.withTransaction(async (client) => {
          await db.insertFulfilled(order("outbox-rollback"), client);
          await enqueueOrderJob(client, jobs, { kind: INVENTORY_KIND, order_id: "outbox-rollback" });
          await publishFulfilled(client, order("outbox-rollback"));
          await publishFulfilled(client, order("outbox-rollback"));
        }),
      /duplicate key|unique/i,
    );

    assert.deepEqual(await counts(db, "outbox-rollback"), { fulfilled: 0, job: 0, outbox: 0 });
    assert.equal(await pendingCount(db.pool), 0);
  } finally {
    await clean(db, "outbox-rollback");
    await db.close();
  }
});

withDb("the relay publishes each key in ord order and removes a row only after the ack", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  try {
    await clean(db, "outbox-order");
    for (const ord of [1, 2, 3]) await publishFulfilled(db.pool, order("outbox-order"), ord);

    const published: Publication[] = [];
    const failure = await relayUntil(
      db.pool,
      async (publication) => {
        published.push(publication);
      },
      () => published.length === 3,
    );

    assert.equal(failure, undefined);
    assert.deepEqual(
      published.map((publication) => publication.ord),
      [1, 2, 3],
      "a key's events are published in ord order",
    );
    assert.equal(await pendingCount(db.pool), 0, "an acknowledged row is removed");
  } finally {
    await clean(db, "outbox-order");
    await db.close();
  }
});

withDb("a blocked earlier event holds later events for the same key", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  try {
    await clean(db, "outbox-blocked");
    await publishFulfilled(db.pool, order("outbox-blocked"), 1);
    await publishFulfilled(db.pool, order("outbox-blocked"), 2);

    const attempts: number[] = [];
    const controller = new AbortController();
    let failFirst = true;
    const failure = await runRelay({
      pool: db.pool,
      kinds: [FULFILLED_KIND],
      publish: async (publication) => {
        attempts.push(publication.ord);
        if (failFirst) {
          failFirst = false;
          throw new Error("broker unreachable");
        }
        controller.abort();
      },
      signal: controller.signal,
      sleep: async () => {},
      onWarning: () => {},
    });

    assert.equal(failure, undefined);
    assert.deepEqual(attempts, [1, 1], "ord 2 is never published before ord 1");
    assert.deepEqual(await pending(db.pool), [{ key: "outbox-blocked", ord: 2 }]);
  } finally {
    await clean(db, "outbox-blocked");
    await db.close();
  }
});

withDb("a relay selects only its owned kinds from a shared table", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  const key = "outbox-foreign";
  try {
    await clean(db, key);
    await publishOrderPlaced(db.pool, { order_id: key, item: "widget", quantity: 1 }, 1);
    await publishFulfilled(db.pool, order(key), 2);

    const foreign: Publication[] = [];
    const controller = new AbortController();
    const stop = setTimeout(() => controller.abort(), 50);
    const failure = await runRelay({
      pool: db.pool,
      kinds: [FULFILLED_KIND],
      publish: async (publication) => {
        foreign.push(publication);
      },
      signal: controller.signal,
      sleep: async () => {},
      onWarning: () => {},
    });
    clearTimeout(stop);
    assert.equal(failure, undefined);
    assert.deepEqual(foreign, [], "the fulfillment owner never receives order_placed");
    assert.deepEqual(await pending(db.pool), [
      { key, ord: 1 },
      { key, ord: 2 },
    ]);

    await db.pool.query("DELETE FROM sol_outbox WHERE aggregate_key = $1 AND ord = 1", [key]);
    const owned: Publication[] = [];
    const ownedController = new AbortController();
    const ownedFailure = await runRelay({
      pool: db.pool,
      kinds: [FULFILLED_KIND],
      publish: async (publication) => {
        owned.push(publication);
        ownedController.abort();
      },
      signal: ownedController.signal,
      sleep: async () => {},
    });
    assert.equal(ownedFailure, undefined);
    assert.deepEqual(owned.map((publication) => publication.kind), [FULFILLED_KIND]);
    assert.equal(await pendingCount(db.pool), 0);
  } finally {
    await clean(db, key);
    await db.close();
  }
});

withDb("two kind owners on one table publish their own rows in key order", async () => {
  const db = await makeDb(POSTGRES_URL!);
  await applyMigrations(db.pool);
  const key = "outbox-two-owners";
  try {
    await clean(db, key);
    await publishOrderPlaced(db.pool, { order_id: key, item: "widget", quantity: 1 }, 1);
    await publishFulfilled(db.pool, order(key), 2);

    const placed: Publication[] = [];
    const placedController = new AbortController();
    const placedFailure = await runRelay({
      pool: db.pool,
      kinds: [ORDER_PLACED_KIND],
      publish: async (publication) => {
        placed.push(publication);
        placedController.abort();
      },
      signal: placedController.signal,
      sleep: async () => {},
    });
    assert.equal(placedFailure, undefined);
    assert.deepEqual(placed.map((publication) => publication.kind), [ORDER_PLACED_KIND]);
    assert.deepEqual(await pending(db.pool), [{ key, ord: 2 }]);

    const fulfilled: Publication[] = [];
    const fulfilledController = new AbortController();
    const fulfilledFailure = await runRelay({
      pool: db.pool,
      kinds: [FULFILLED_KIND],
      publish: async (publication) => {
        fulfilled.push(publication);
        fulfilledController.abort();
      },
      signal: fulfilledController.signal,
      sleep: async () => {},
    });
    assert.equal(fulfilledFailure, undefined);
    assert.deepEqual(fulfilled.map((publication) => publication.kind), [FULFILLED_KIND]);
    assert.equal(await pendingCount(db.pool), 0);
  } finally {
    await clean(db, key);
    await db.close();
  }
});

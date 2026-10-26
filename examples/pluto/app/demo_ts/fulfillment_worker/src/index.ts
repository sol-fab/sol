import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";

import {
  connectTopic,
  kafkaConfigFromEnv,
  publish,
  provisionDlqTopic,
  wireCrashListener,
  wrapEachMessage,
} from "@sol-fab/kafka";
import { runJobs } from "@sol-fab/jobs";
import { makeLokiPusher } from "@sol-fab/obs";
import { runRelay } from "@sol-fab/outbox";
import { createWorkerHealth, runWorker } from "@sol-fab/worker";
import {
  ORDER_FULFILLED,
  ORDER_PLACED,
  decodeOrderFulfilled,
  decodeOrderPlaced,
} from "@demo-ts/contract";
import { initTracing } from "./tracing.js";
import { makeWorkerMetrics } from "./metrics.js";
import { makeDb } from "./db.js";
import { makeOrderJobs } from "./jobs.js";
import { FULFILLED_KIND } from "./outbox.js";
import { intEnv, requiredPostgresUrl, requiredRegistry, setting } from "./config.js";
import { handleOrder, type OrderHandlerDeps } from "./handler.js";
import { supervise, watch } from "./runner-supervision.js";

const KAFKA_ENV = kafkaConfigFromEnv();
const TOPIC_NAME = ORDER_PLACED.name;
const GROUP_ID = "sol-demo-ts-fulfillment-worker";
const PARTITIONS = ORDER_PLACED.partitions;

const METRICS_PORT = intEnv("METRICS_PORT", 9090);
const LOKI_URL = setting("LOKI_URL");
const TEMPO_URL = setting("TEMPO_URL");

const log = makeLokiPusher({
  lokiUrl: LOKI_URL,
  service: "fulfillment-worker-ts",
});
const { tracer, shutdown: shutdownTracing } = initTracing("fulfillment-worker-ts", TEMPO_URL);
const {
  register: metricsRegister,
  messagesTotal,
  decodeErrorsTotal,
  messageDuration,
  outboxPublishedTotal,
  outboxPending,
  outboxOldestPendingSeconds,
} = makeWorkerMetrics();
const health = createWorkerHealth();

async function main() {
  const postgresUrl = requiredPostgresUrl();
  const db = await makeDb(postgresUrl);
  const orderJobs = makeOrderJobs(log, {
    markConfirmed: async (orderId) => {
      await db.markConfirmed(orderId);
    },
  });
  const deps: OrderHandlerDeps = {
    store: db,
    jobs: orderJobs,
    log,
    tracer,
    messagesTotal,
    messageDuration,
  };

  const kafka = new Kafka({ clientId: "fulfillment-worker-ts", ...KAFKA_ENV });

  const producer = kafka.producer();
  await producer.connect();
  await provisionDlqTopic({
    kafka,
    groupId: GROUP_ID,
    source: { name: TOPIC_NAME, partitions: PARTITIONS },
  });

  const fulfilledTopic = await connectTopic({
    kafka,
    registryUrl: requiredRegistry(),
    contract: ORDER_FULFILLED,
  });

  const consumer = kafka.consumer({ groupId: GROUP_ID });
  await consumer.connect();
  await consumer.subscribe({ topic: TOPIC_NAME, fromBeginning: false });

  const metricsServer = createServer((req, res) => {
    const path = req.url ?? "";
    if (path === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok\n");
      return;
    }
    const healthResponse = health.response(path);
    if (healthResponse !== undefined) {
      res.writeHead(healthResponse.status, { "content-type": "text/plain; charset=utf-8" });
      res.end(healthResponse.body);
      return;
    }
    if (path === "/metrics") {
      metricsRegister.metrics().then((body) => {
        res.writeHead(200, { "content-type": metricsRegister.contentType });
        res.end(body);
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  metricsServer.listen(METRICS_PORT, () => {
    console.log(`[fulfillment-worker-ts] metrics on :${METRICS_PORT}`);
  });

  const onDecodeError = (err: unknown) => {
    console.error(`[worker] undecodable message, dead-lettered: ${String(err)}`);
    log("error", "undecodable message, dead-lettered", { error: String(err) });
  };

  consumer.on(consumer.events.GROUP_JOIN, () => {
    health.onAssignment(1);
  });
  consumer.on(consumer.events.HEARTBEAT, () => {
    health.onPoll();
  });

  await consumer.run({
    eachMessage: wrapEachMessage({
      decode: decodeOrderPlaced,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError,
      dlq: {
        publisher: {
          publish: async (record) => {
            await producer.send({ topic: record.topic, messages: [record] });
          },
        },
        groupId: GROUP_ID,
        sourceTopic: TOPIC_NAME,
      },
      handler: ({ message, traceContext }) => handleOrder(message, traceContext, deps),
    }),
  });

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-fulfillment-worker" })
          .catch((err) => console.error(`[fulfillment-worker-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  const supervisor = supervise((message) => console.error(`[fulfillment-worker-ts] ${message}`));

  const outboxAbort = new AbortController();
  const outboxRunning = watch(
    runRelay({
    pool: db.pool,
    publish: async (publication) => {
      if (publication.kind !== FULFILLED_KIND) {
        throw new Error(
          `outbox kind ${publication.kind} is not this relay's ${FULFILLED_KIND}; its owner publishes it`,
        );
      }
      const event = decodeOrderFulfilled(JSON.parse(publication.payload));
      const key = fulfilledTopic.key(event);
      if (key !== publication.key) {
        throw new Error(`outbox key ${publication.key} does not match the contract key ${key}`);
      }
      await publish(producer, fulfilledTopic, event);
    },
    signal: outboxAbort.signal,
    pollIntervalS: 0.5,
    onPublication: (publication, status) => {
      outboxPublishedTotal.inc({ kind: publication.kind, status });
    },
    onMetrics: (metrics) => {
      outboxPending.reset();
      for (const gauge of metrics.pendingByKind) {
        outboxPending.set({ kind: gauge.kind }, gauge.value);
      }
      outboxOldestPendingSeconds.reset();
      for (const gauge of metrics.oldestPendingSecondsByKind) {
        outboxOldestPendingSeconds.set({ kind: gauge.kind }, gauge.value);
      }
    },
    onWarning: (fields, message) => {
      console.error(`[fulfillment-worker-ts] ${message}`, fields);
      log("error", message, fields);
    },
    }),
    "outbox relay",
    supervisor,
  );

  const jobsAbort = new AbortController();
  const jobsRunning = watch(
    runJobs({
    pool: db.pool,
    contract: orderJobs,
    signal: jobsAbort.signal,
    pollIntervalS: 0.5,
    onOutcome: (outcome) => {
      log("info", "job processed", {
        kind: outcome.kind,
        status: outcome.status,
        duration_s: outcome.durationS.toFixed(3),
      });
    },
    onWarning: (fields, message) => {
      console.error(`[fulfillment-worker-ts] ${message}`, fields);
      log("error", message, fields);
    },
    }),
    "jobs runner",
    supervisor,
  );

  const lifecycle = runWorker({
    drain: async () => {
      outboxAbort.abort();
      jobsAbort.abort();
      await Promise.all([outboxRunning, jobsRunning]);
      await consumer.disconnect();
    },
    onDrainStart: () => {
      console.log("[fulfillment-worker-ts] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [
      () => log.flush(),
      () => producer.disconnect(),
      async () => {
        metricsServer.close();
      },
      async () => {
        await db.close();
      },
      () => shutdownTracing(),
      async () => {
        const failure = supervisor.failure();
        if (failure) throw failure;
      },
    ],
  });
  supervisor.attach(lifecycle);

  wireCrashListener(consumer, {
    onCrash: (error) => console.error(`[fulfillment-worker-ts] consumer crashed: ${String(error)}`),
    onFailStop: (reason) => {
      console.error(`[fulfillment-worker-ts] handler failed a fact (fail-stop): ${reason}`);
      return lifecycle.shutdown();
    },
  });
}

main().catch((err) => {
  console.error("[fulfillment-worker-ts] fatal:", err);
  process.exit(1);
});

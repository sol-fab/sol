import Fastify from "fastify";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";
import { context, propagation, SpanStatusCode } from "@opentelemetry/api";
import { randomBytes } from "node:crypto";

import { connectTopic, kafkaConfigFromEnv, publish } from "@sol-fab/kafka";
import { ORDER_PLACED, decodeOrderPlaced } from "@demo-ts/contract";
import { traceparentOf, routeLabel, statusClassOf, makeLokiPusher } from "@sol-fab/obs";
import { runRelay } from "@sol-fab/outbox";
import { runService, type ServiceLifecycle } from "@sol-fab/svc";
import { initTracing, SpanKind } from "./tracing.js";
import { makeSvcMetrics } from "./metrics.js";
import { makeDb } from "./db.js";
import { confirmationJobs } from "./jobs.js";
import { placeOrder } from "./orders.js";
import { ORDER_PLACED_KIND } from "./outbox.js";
import { supervise, watch } from "./runner-supervision.js";

function setting(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function intEnv(name: string, fallback: number): number {
  const raw = setting(name);
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw new Error(`${name}=${JSON.stringify(raw)} is not a number`);
  }
  return n;
}

const PORT = intEnv("PORT", 8080);
function requiredEnv(name: string, why: string): string {
  const value = setting(name);
  if (!value) {
    throw new Error(`${name} is not set: ${why}`);
  }
  return value;
}

const KAFKA_ENV = kafkaConfigFromEnv();
const SCHEMA_REGISTRY_URL = requiredEnv(
  "SCHEMA_REGISTRY_URL",
  "the outbox relay publishes through the registered contract",
);
const POSTGRES_URL = requiredEnv(
  "POSTGRES_URL",
  "POST /orders commits the order row, its job and its outbox intent in one transaction",
);
const LOKI_URL = setting("LOKI_URL");
const TEMPO_URL = setting("TEMPO_URL");
const TOPIC_NAME = ORDER_PLACED.name;

const log = makeLokiPusher({
  lokiUrl: LOKI_URL,
  service: "order-svc-ts",
});
const { tracer, shutdown: shutdownTracing } = initTracing("order-svc-ts", TEMPO_URL);
const {
  register: metricsRegister,
  requestsTotal,
  requestDuration,
  outboxPublishedTotal,
  outboxPending,
  outboxOldestPendingSeconds,
} = makeSvcMetrics();

async function main() {
  console.log(`[order-svc-ts] brokers=${KAFKA_ENV.brokers} registry=${SCHEMA_REGISTRY_URL} topic=${TOPIC_NAME}`);

  const kafka = new Kafka({ clientId: "order-svc-ts", ...KAFKA_ENV });

  const topic = await connectTopic({
    kafka,
    registryUrl: SCHEMA_REGISTRY_URL,
    contract: ORDER_PLACED,
  });
  console.log(`[order-svc-ts] contract resolved, schema id=${topic.schemaId}`);

  const producer = kafka.producer();
  await producer.connect();

  const db = await makeDb(POSTGRES_URL);
  const jobs = confirmationJobs();

  const app = Fastify({ logger: false });

  let lifecycle: ServiceLifecycle | undefined;
  const supervisor = supervise((message) => console.error(`[order-svc-ts] ${message}`));

  app.addHook("onResponse", async (req, reply) => {
    const route = routeLabel(req.routeOptions?.url);
    const statusClass = statusClassOf(reply.statusCode);
    requestsTotal.inc({ method: req.method, route, status_class: statusClass });
    requestDuration.observe({ method: req.method, route }, reply.elapsedTime / 1000);
  });

  app.setErrorHandler((err, _req, reply) => {
    console.error(`[order-svc-ts] request error: ${String(err)}`);
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) {
      reply.code(status).send({ error: "internal server error" });
    } else {
      reply.code(status).send({ error: (err as Error).message });
    }
  });

  app.get("/healthz", async () => ({ status: "ok" }));
  app.get("/readyz", async (_req, reply) => {
    if (lifecycle?.isReady() ?? true) return { status: "ready" };
    return reply.code(503).send({ status: "shutting down" });
  });
  app.get("/metrics", async (_req, reply) => {
    reply.header("content-type", metricsRegister.contentType);
    return metricsRegister.metrics();
  });

  app.post(
    "/orders",
    {
      schema: {
        body: {
          type: "object",
          required: ["order_id", "item", "quantity"],
          properties: {
            order_id: { type: "string", minLength: 1 },
            item: { type: "string", minLength: 1 },
            quantity: { type: "integer" },
          },
        },
      },
    },
    async (req, reply) => {
      const body = req.body as { order_id: string; item: string; quantity: number };
      const correlationId =
        (req.headers["x-correlation-id"] as string | undefined) ?? randomBytes(4).toString("hex");

      const parentContext = propagation.extract(context.active(), req.headers);
      const span = tracer.startSpan(
        "receive_order",
        { kind: SpanKind.PRODUCER },
        parentContext,
      );
      try {
        span.setAttribute("order_id", body.order_id);
        span.setAttribute("item", body.item);

        const traceparent = traceparentOf(span);
        log("info", "order received", {
          order_id: body.order_id,
          item: body.item,
          correlation_id: correlationId,
          trace_id: span.spanContext().traceId,
        });

        const order = {
          order_id: body.order_id,
          item: body.item,
          quantity: body.quantity,
          correlation_id: correlationId,
          traceparent,
        };
        await db.withTransaction(async (client) => {
          await placeOrder(db, client, order, jobs);
        });

        const view = await db.readOrder(order.order_id);
        reply.code(202);
        return { order_id: order.order_id, status: view?.status ?? "accepted" };
      } catch (err) {
        span.recordException(err as Error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw err;
      } finally {
        span.end();
      }
    }
  );

  app.get("/orders/:order_id", async (req, reply) => {
    const { order_id } = req.params as { order_id: string };
    const view = await db.readOrder(order_id);
    if (!view) {
      return reply.code(404).send({ error: "no such order", order_id });
    }
    return view;
  });

  await app.listen({ port: PORT, host: "0.0.0.0" });
  console.log(`[order-svc-ts] listening on :${PORT}`);

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "sol-demo-ts-order-svc" })
          .catch((err) => console.error(`[order-svc-ts] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  const outboxAbort = new AbortController();
  const outboxRunning = watch(
    runRelay({
    pool: db.pool,
    kinds: [ORDER_PLACED_KIND],
    publish: async (publication) => {
      if (publication.kind !== ORDER_PLACED_KIND) {
        throw new Error(
          `outbox kind ${publication.kind} is not this relay's ${ORDER_PLACED_KIND}; its owner publishes it`,
        );
      }
      const event = decodeOrderPlaced(JSON.parse(publication.payload));
      const key = topic.key(event);
      if (key !== publication.key) {
        throw new Error(`outbox key ${publication.key} does not match the contract key ${key}`);
      }
      const traceparent = await db.traceparentOf(publication.key);
      await publish(producer, topic, event, traceparent ? { headers: { traceparent } } : undefined);
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
      console.error(`[order-svc-ts] ${message}`, fields);
      log("error", message, fields);
    },
    }),
    "outbox relay",
    supervisor,
  );

  lifecycle = runService({
    drain: async () => {
      outboxAbort.abort();
      await outboxRunning;
      await app.close();
    },
    onDrainStart: () => {
      console.log("[order-svc-ts] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [
      () => log.flush(),
      () => producer.disconnect(),
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
}

main().catch((err) => {
  console.error("[order-svc-ts] fatal:", err);
  process.exit(1);
});

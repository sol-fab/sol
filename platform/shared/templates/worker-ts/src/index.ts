import { createServer } from "node:http";
import { Kafka } from "kafkajs";
import { Pushgateway } from "@prometheus-io/client";

import {
  ACK,
  kafkaConfigFromEnv,
  provisionDlqTopic,
  wireCrashListener,
  wrapEachMessage,
  type Outcome,
} from "@sol-fab/kafka";
import { makeLokiPusher } from "@sol-fab/obs";
import { createWorkerHealth, runWorker } from "@sol-fab/worker";
import { decodePayload } from "./wire.js";
import { makeWorkerMetrics } from "./metrics.js";

function setting(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function intEnv(name: string, fallback: number): number {
  const raw = setting(name);
  if (raw === undefined) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) throw new Error(`${name}=${JSON.stringify(raw)} is not a number`);
  return n;
}

const KAFKA_ENV = kafkaConfigFromEnv();
const TOPIC_NAME = setting("TOPIC") ?? "{{domain}}-{{name}}";
const GROUP_ID = "{{domain}}-{{name}}-worker";
const PARTITIONS = 3;
const METRICS_PORT = intEnv("METRICS_PORT", 9090);

const log = makeLokiPusher({
  lokiUrl: setting("LOKI_URL"),
  service: "{{binary}}",
  labels: { team: "{{domain}}" },
});
const { register: metricsRegister, messagesTotal, decodeErrorsTotal, messageDuration } =
  makeWorkerMetrics();
const health = createWorkerHealth();

async function handle(message: ReturnType<typeof decodePayload>): Promise<Outcome> {
  const start = process.hrtime.bigint();
  try {
    log("info", "handled", { id: message.id });
    console.log(`[{{binary}}] handled id=${message.id}`);
    messagesTotal.inc({ status: "ok" });
    return ACK;
  } finally {
    messageDuration.observe(Number(process.hrtime.bigint() - start) / 1e9);
  }
}

async function main() {
  const kafka = new Kafka({ clientId: "{{binary}}", ...KAFKA_ENV });

  const producer = kafka.producer();
  await producer.connect();
  await provisionDlqTopic({
    kafka,
    groupId: GROUP_ID,
    source: { name: TOPIC_NAME, partitions: PARTITIONS },
  });

  const consumer = kafka.consumer({ groupId: GROUP_ID });
  await consumer.connect();
  // Match the OCaml worker: a new or expired consumer group must process the retained
  // backlog rather than silently starting at the latest offset. Committed offsets still
  // win; this only decides where a group with no offset begins.
  await consumer.subscribe({ topic: TOPIC_NAME, fromBeginning: true });

  const metricsServer = createServer((req, res) => {
    const path = req.url ?? "";
    if (path === "/metrics") {
      metricsRegister.metrics().then((body) => {
        res.writeHead(200, { "content-type": metricsRegister.contentType });
        res.end(body);
      });
      return;
    }
    const response = health.response(path);
    if (response !== undefined) {
      res.writeHead(response.status, { "content-type": "text/plain; charset=utf-8" });
      res.end(response.body);
      return;
    }
    res.writeHead(404);
    res.end();
  });
  metricsServer.listen(METRICS_PORT, () => {
    console.log(`[{{binary}}] metrics on :${METRICS_PORT}`);
  });

  consumer.on(consumer.events.GROUP_JOIN, () => {
    health.onAssignment(1);
  });
  consumer.on(consumer.events.HEARTBEAT, () => {
    health.onPoll();
  });

  const pushgatewayUrl = setting("PUSHGATEWAY_URL");
  const pushInterval = pushgatewayUrl
    ? setInterval(() => {
        new Pushgateway(pushgatewayUrl, {}, metricsRegister)
          .pushAdd({ jobName: "{{binary}}" })
          .catch((err) => console.error(`[{{binary}}] pushgateway push failed: ${String(err)}`));
      }, 3000)
    : undefined;

  // Start the supervised lifecycle and crash listener before the consumer starts. A
  // non-retriable join/sync failure emits CRASH before `consumer.run` resolves; installing
  // the listener afterwards misses it and leaves the process running without a consumer.
  const lifecycle = runWorker({
    drain: () => consumer.disconnect(),
    onDrainStart: () => {
      console.log("[{{binary}}] draining...");
      if (pushInterval) clearInterval(pushInterval);
    },
    shutdownHooks: [
      () => log.flush(),
      () => producer.disconnect(),
      async () => {
        metricsServer.close();
      },
    ],
  });

  wireCrashListener(consumer, {
    onCrash: (error) => console.error(`[{{binary}}] consumer crashed: ${String(error)}`),
    onFailStop: (reason) => {
      console.error(`[{{binary}}] handler failed a fact (fail-stop): ${reason}`);
      return lifecycle.shutdown();
    },
  });

  await consumer.run({
    eachMessage: wrapEachMessage({
      decode: decodePayload,
      decodeErrorCounter: decodeErrorsTotal,
      onDecodeError: (err) => {
        log("error", "undecodable message, dead-lettered", { error: String(err) });
      },
      dlq: {
        publisher: {
          publish: async (record) => {
            await producer.send({ topic: record.topic, messages: [record] });
          },
        },
        groupId: GROUP_ID,
        sourceTopic: TOPIC_NAME,
      },
      handler: ({ message }) => handle(message),
    }),
  });
}

main().catch((err) => {
  console.error("[{{binary}}] fatal:", err);
  process.exit(1);
});

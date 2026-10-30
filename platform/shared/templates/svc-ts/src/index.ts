import Fastify from "fastify";
import { makeLokiPusher, routeLabel, statusClassOf } from "@sol-fab/obs";
import { createWorkloadIdentityGuard, runService, type ServiceLifecycle } from "@sol-fab/svc";
import { makeSvcMetrics } from "./metrics.js";

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isInteger(n) ? n : fallback;
}

const PORT = intEnv("PORT", 8080);
const log = makeLokiPusher({ lokiUrl: process.env.LOKI_URL, service: "{{binary}}" });
const { register, requestsTotal, requestDuration } = makeSvcMetrics();

const app = Fastify({ logger: false });
let lifecycle: ServiceLifecycle | undefined;

// Sol-to-Sol callers authenticate with the projected workload identity by
// default (DEC-063). These are the explicit external exceptions; add a route
// here deliberately, because there is no public default. The guard reads
// SOL_UNIT, SOL_CALLED_BY and SOL_TRUSTED_WORKLOAD_ISSUER, which Sol projects
// from the declared calls graph and the target's discovery -- never from the
// incoming token -- and fails closed when they are missing.
const PUBLIC_PATHS = new Set(["/", "/healthz", "/readyz", "/metrics"]);
const workloadIdentity = createWorkloadIdentityGuard({
  isPublic: (request) => request.path !== undefined && PUBLIC_PATHS.has(request.path),
});

app.addHook("onRequest", async (req, reply) => {
  const path = req.url.split("?")[0] || req.url;
  const decision = await workloadIdentity.check({
    authorization: req.headers.authorization,
    path,
  });
  if (!decision.ok) {
    if (decision.status >= 500) {
      // The guard's detail can name the issuer/JWKS URL. Keep it in operator logs, not
      // in an unauthenticated response; this mirrors Sol's OCaml services.
      console.error(`[svc] workload identity check failed: ${decision.message}`);
      await reply.code(decision.status).send({ error: "Internal server error" });
    } else {
      await reply.code(decision.status).send({ error: decision.message });
    }
  }
});

app.addHook("onResponse", async (req, reply) => {
  const route = routeLabel(req.routeOptions?.url);
  requestsTotal.inc({ method: req.method, route, status_class: statusClassOf(reply.statusCode) });
  requestDuration.observe({ method: req.method, route }, reply.elapsedTime / 1000);
});

app.get("/healthz", async () => ({ status: "ok" }));

app.get("/readyz", async (_req, reply) => {
  if (lifecycle?.isReady() ?? true) return { status: "ready" };
  return reply.code(503).send({ status: "shutting down" });
});

app.get("/metrics", async (_req, reply) => {
  reply.header("content-type", register.contentType);
  return register.metrics();
});

app.get("/", async () => ({ status: "ok" }));

async function main() {
  await app.listen({ port: PORT, host: "0.0.0.0" });
  log("info", "listening", { port: String(PORT) });
  lifecycle = runService({
    drain: () => app.close(),
    shutdownHooks: [() => log.flush()],
  });
}

main().catch((err) => {
  console.error(String(err));
  process.exit(1);
});

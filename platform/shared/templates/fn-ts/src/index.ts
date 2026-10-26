import { runFn } from "@sol-fab/fn";
import { makeLokiPusher } from "@sol-fab/obs";

// A Sol -fn is a run-once Kubernetes CronJob. This process runs exactly once;
// Sol schedules the CronJob, and a manual invocation is a Job created from it.
const log = makeLokiPusher({
  lokiUrl: process.env.LOKI_URL,
  service: "{{binary}}",
});

void runFn({
  job: process.env.SOL_PUSHGATEWAY_JOB ?? "{{binary}}",
  pushgatewayUrl: process.env.PUSHGATEWAY_URL,
  run: async () => {
    try {
      log("info", "running", {});
      // TODO: do one unit of work. Throw on failure; the process exits 1.
    } finally {
      await log.flush();
    }
  },
}).catch((error: unknown) => {
  console.error(`[{{binary}}] fatal: ${String(error)}`);
  process.exit(1);
});

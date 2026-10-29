/** GCP Pub/Sub push task consumer.
 *
 * Pub/Sub delivers one message per HTTP request; there is no SQS-style
 * partial-batch response. Ack is 200, retryable failure is 500, and a malformed
 * push or envelope is 400 so it does not create an uncontrolled retry loop.
 * Terminal failure and dead-lettering remain provider policy (max attempts).
 */
import http from "node:http";
import { handleEnvelope, parseEnvelope } from "./task.js";

export interface PushResult {
  status: number;
  body: string;
}

const maxBodyBytes = 512 * 1024;

interface PushBody {
  message?: { data?: unknown };
}

export function handlePush(raw: string): PushResult {
  let body: PushBody;
  try {
    body = JSON.parse(raw) as PushBody;
  } catch (error) {
    console.error(`task_consumer malformed Pub/Sub push: ${String(error)}`);
    return { status: 400, body: "malformed Pub/Sub push" };
  }
  const data = body.message?.data;
  if (typeof data !== "string") {
    console.error("task_consumer Pub/Sub push has no message.data");
    return { status: 400, body: "message.data is required" };
  }
  let payload: string;
  try {
    payload = Buffer.from(data, "base64").toString("utf8");
  } catch (error) {
    console.error(`task_consumer malformed Pub/Sub data: ${String(error)}`);
    return { status: 400, body: "message.data is not base64" };
  }
  const parsed = parseEnvelope(payload);
  if (!parsed.ok) {
    console.error(`task_consumer malformed task envelope: ${parsed.error}`);
    return { status: 400, body: parsed.error };
  }
  if (handleEnvelope(parsed.envelope) === "retry") {
    return { status: 500, body: "task requested retry" };
  }
  return { status: 200, body: "" };
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > maxBodyBytes) {
        reject(new Error("request body is too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export function createServer(): http.Server {
  return http.createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok\n");
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405, { "content-type": "text/plain" });
      res.end("method not allowed\n");
      return;
    }
    try {
      const result = handlePush(await readBody(req));
      res.writeHead(result.status, { "content-type": "text/plain" });
      res.end(result.body);
    } catch (error) {
      console.error(`task_consumer request failed: ${String(error)}`);
      res.writeHead(400, { "content-type": "text/plain" });
      res.end("bad request\n");
    }
  });
}

if (require.main === module) {
  const port = Number(process.env.PORT ?? 8080);
  const server = createServer();
  server.listen(port, "0.0.0.0", () => {
    console.log(`task_consumer listening on ${port}`);
  });
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

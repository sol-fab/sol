import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { poolConfig as servicePoolConfig } from "../order_svc/src/db.js";
import { poolConfig as workerPoolConfig } from "../fulfillment_worker/src/db.js";

// A CA the helper merely has to carry through, so the file need not be a real certificate.
const CA = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n";

function caFile(): string {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sol-db-ca-")), "ca.pem");
  fs.writeFileSync(file, CA);
  return file;
}

interface Ssl {
  ca?: string;
  rejectUnauthorized?: boolean;
  checkServerIdentity?: (hostname: string, cert: unknown) => Error | undefined;
}

const impls = [
  ["order-svc", servicePoolConfig],
  ["fulfillment-worker", workerPoolConfig],
] as const;

for (const [name, poolConfig] of impls) {
  test(`${name}: verify-ca verifies the chain, not the hostname`, () => {
    const ca = caFile();
    const config = poolConfig(
      `postgresql://sol_app:pw@10.0.0.5:5432/app?sslmode=verify-ca&sslrootcert=${ca}`,
    );
    // The TLS parameters move out of the connection string so pg-connection-string cannot
    // re-interpret `verify-ca` as `verify-full`.
    assert.equal(config.connectionString, "postgresql://sol_app:pw@10.0.0.5:5432/app");
    const ssl = config.ssl as Ssl;
    assert.equal(ssl.ca, CA);
    assert.equal(ssl.rejectUnauthorized, true);
    assert.equal(typeof ssl.checkServerIdentity, "function");
    // libpq's verify-ca succeeds against a certificate issued for the instance, not the address.
    assert.equal(ssl.checkServerIdentity?.("10.0.0.5", {}), undefined);
  });

  test(`${name}: verify-full keeps node's hostname check`, () => {
    const ca = caFile();
    const config = poolConfig(
      `postgresql://sol_app:pw@db.example:5432/app?sslmode=verify-full&sslrootcert=${ca}`,
    );
    const ssl = config.ssl as Ssl;
    assert.equal(ssl.ca, CA);
    assert.equal(ssl.rejectUnauthorized, true);
    assert.equal(ssl.checkServerIdentity, undefined);
  });

  test(`${name}: a URL that names no CA is passed through untouched`, () => {
    const url = "postgresql://sol_app:pw@db.example:5432/app";
    assert.deepEqual(poolConfig(url), { connectionString: url });
  });
}

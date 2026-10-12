import fs from "node:fs";
import pg from "pg";

// Sol delivers `POSTGRES_URL` as a libpq URL that names the managed database's CA and asks for
// chain verification, for example
// `?sslmode=verify-ca&sslrootcert=/etc/sol/db-ca/ca.pem` (the `<target>-db-ca` ConfigMap the
// deploy mounts into every consuming namespace). libpq's `verify-ca` verifies the chain but
// *not* the hostname, because the provider issues the server certificate for the instance, not
// for the address the URL dials. node-postgres aliases `verify-ca` to `verify-full`, which adds
// hostname verification and then fails with `ERR_TLS_CERT_ALTNAME_INVALID`. Honour libpq's
// semantics here rather than inheriting the alias. (The worker and the service each carry their
// own copy: they are separate npm workspace packages that consume only published dependencies.)
export function poolConfig(postgresUrl: string): pg.PoolConfig {
  const url = new URL(postgresUrl);
  const mode = url.searchParams.get("sslmode");
  const caPath = url.searchParams.get("sslrootcert");
  if (!caPath || (mode !== "verify-ca" && mode !== "verify-full")) {
    return { connectionString: postgresUrl };
  }
  url.searchParams.delete("sslmode");
  url.searchParams.delete("sslrootcert");
  return {
    connectionString: url.toString(),
    ssl: {
      ca: fs.readFileSync(caPath, "utf8"),
      rejectUnauthorized: true,
      // `verify-ca` verifies the chain only; `verify-full` keeps node's hostname check.
      ...(mode === "verify-ca" ? { checkServerIdentity: () => undefined } : {}),
    },
  };
}

export interface FulfilledOrder {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
}

export async function makeDb(postgresUrl: string) {
  const pool = new pg.Pool(poolConfig(postgresUrl));
  pool.on("error", (err) => {
    console.error(`[fulfillment-worker-ts] idle pg client error: ${String(err)}`);
  });
  return {
    pool,
    insertFulfilled: async (order: FulfilledOrder, client?: pg.PoolClient): Promise<boolean> => {
      const result = await (client ?? pool).query(
        `INSERT INTO fulfilled_orders_ts (order_id, item, quantity, correlation_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [order.order_id, order.item, order.quantity, order.correlation_id]
      );
      return (result.rowCount ?? 0) > 0;
    },
    markFulfilled: async (orderId: string, client?: pg.PoolClient): Promise<void> => {
      await (client ?? pool).query(
        `UPDATE orders_ts
            SET status = 'fulfilled', fulfilled_at = now()
          WHERE order_id = $1 AND fulfilled_at IS NULL`,
        [orderId]
      );
    },
    markConfirmed: async (orderId: string, client?: pg.PoolClient): Promise<void> => {
      const target = client ?? pool;
      const progress = await target.query(
        `SELECT fulfilled_at IS NOT NULL AS fulfilled, confirmed_at IS NOT NULL AS confirmed
           FROM orders_ts WHERE order_id = $1`,
        [orderId]
      );
      const row = progress.rows[0] as { fulfilled: boolean; confirmed: boolean } | undefined;
      if (!row) {
        throw new Error(`order ${orderId} is missing`);
      }
      if (row.confirmed) {
        return;
      }
      if (!row.fulfilled) {
        throw new Error(`order ${orderId} is not fulfilled yet`);
      }
      await target.query(
        `INSERT INTO order_confirmations_ts (order_id)
         VALUES ($1)
         ON CONFLICT (order_id) DO NOTHING`,
        [orderId]
      );
      await target.query(
        `UPDATE orders_ts
            SET status = 'confirmed', confirmed_at = now()
          WHERE order_id = $1 AND fulfilled_at IS NOT NULL AND confirmed_at IS NULL`,
        [orderId]
      );
    },
    withTransaction: async <T>(body: (client: pg.PoolClient) => Promise<T>): Promise<T> => {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const result = await body(client);
        await client.query("COMMIT");
        return result;
      } catch (err) {
        await client.query("ROLLBACK").catch(() => {});
        throw err;
      } finally {
        client.release();
      }
    },
    close: () => pool.end(),
  };
}

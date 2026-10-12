import fs from "node:fs";
import pg from "pg";

// Sol delivers `POSTGRES_URL` as a libpq URL that names the managed database's CA and asks for
// chain verification, for example
// `?sslmode=verify-ca&sslrootcert=/etc/sol/db-ca/ca.pem` (the `<target>-db-ca` ConfigMap the
// deploy mounts into every consuming namespace). libpq's `verify-ca` verifies the chain but
// *not* the hostname, because the provider issues the server certificate for the instance, not
// for the address the URL dials. node-postgres aliases `verify-ca` to `verify-full`, which adds
// hostname verification and then fails with `ERR_TLS_CERT_ALTNAME_INVALID`. Honour libpq's
// semantics here rather than inheriting the alias.
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

export type OrderStatus = "accepted" | "fulfilled" | "confirmed";

export interface AcceptedOrder {
  order_id: string;
  item: string;
  quantity: number;
  correlation_id: string;
  traceparent: string;
}

export interface OrderView {
  order_id: string;
  item: string;
  quantity: number;
  status: OrderStatus;
}

export async function makeDb(postgresUrl: string) {
  const pool = new pg.Pool(poolConfig(postgresUrl));
  pool.on("error", (err) => {
    console.error(`[order-svc-ts] idle pg client error: ${String(err)}`);
  });
  return {
    pool,
    insertOrder: async (order: AcceptedOrder, client?: pg.PoolClient): Promise<boolean> => {
      const result = await (client ?? pool).query(
        `INSERT INTO orders_ts (order_id, item, quantity, traceparent)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (order_id) DO NOTHING`,
        [order.order_id, order.item, order.quantity, order.traceparent],
      );
      return (result.rowCount ?? 0) > 0;
    },
    readOrder: async (orderId: string): Promise<OrderView | undefined> => {
      const result = await pool.query(
        `SELECT order_id, item, quantity,
                CASE WHEN confirmed_at IS NOT NULL THEN 'confirmed'
                     WHEN fulfilled_at IS NOT NULL THEN 'fulfilled'
                     ELSE 'accepted' END AS status
           FROM orders_ts
          WHERE order_id = $1`,
        [orderId],
      );
      return result.rows[0] as OrderView | undefined;
    },
    traceparentOf: async (orderId: string): Promise<string | undefined> => {
      const result = await pool.query("SELECT traceparent FROM orders_ts WHERE order_id = $1", [orderId]);
      const row = result.rows[0] as { traceparent: string | null } | undefined;
      return row?.traceparent ?? undefined;
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

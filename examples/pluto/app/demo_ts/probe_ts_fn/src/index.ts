/** A provider-native TypeScript Lambda probe.
 *
 * The image uses the AWS Lambda Node.js base image, so the handler receives the
 * target's invocation directly. The Sol deployment invokes `{}` and requires
 * `{"status":"ok"}`; this is the same run-once contract the OCaml `Fn.Lambda`
 * probe uses, without the `@sol-fab/fn` CronJob adapter (which is not a Lambda
 * runtime).
 */
export async function handler(): Promise<{ status: "ok" }> {
  console.log("[probe-fn-ts] pluto serverless probe ok");
  return { status: "ok" };
}

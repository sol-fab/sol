export type RunnerError = { readonly kind: string; readonly message: string };

export interface Supervisor {
  report(label: string, error: RunnerError): void;
  attach(lifecycle: { shutdown: () => Promise<void> }): void;
  failure(): Error | undefined;
}

export function supervise(post: (message: string) => void): Supervisor {
  let lifecycle: { shutdown: () => Promise<void> } | undefined;
  let failure: Error | undefined;
  const shutDown = (target: { shutdown: () => Promise<void> }): void => {
    void target.shutdown().catch(() => {});
  };
  const report = (label: string, error: RunnerError): void => {
    if (failure) return;
    failure = new Error(`${label} stopped: ${error.message}`);
    post(failure.message);
    if (lifecycle) shutDown(lifecycle);
  };
  const attach = (target: { shutdown: () => Promise<void> }): void => {
    lifecycle = target;
    if (failure) shutDown(target);
  };
  return { report, attach, failure: () => failure };
}

export function watch(
  running: Promise<RunnerError | undefined>,
  label: string,
  supervisor: Supervisor,
): Promise<void> {
  return running.then(
    (error) => {
      if (error) supervisor.report(label, error);
    },
    (error: unknown) => {
      // A rejected runner promise is a terminal failure too. Without this branch the
      // rejection is unhandled and Node exits without running the supervised shutdown.
      supervisor.report(label, { kind: "crash", message: String(error) });
    },
  );
}

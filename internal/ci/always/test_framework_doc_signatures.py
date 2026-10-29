import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GUARD = REPO / "internal/ci/always/check_framework_doc_signatures.py"
SVC = "framework/ocaml/sol-svc/sol-svc.md"
KAFKA = "framework/ocaml/kafka-eio-service/kafka-eio-service.md"
WORKER = "framework/ocaml/sol-worker/sol-worker.md"
FN = "framework/ocaml/sol-fn/sol-fn.md"
OBS = "framework/ocaml/sol-obs/sol-obs.md"
JOBS = "framework/ocaml/sol-jobs/sol-jobs.md"
OUTBOX = "framework/ocaml/sol-outbox/sol-outbox.md"
TASK = "framework/ocaml/sol-task/sol-task.md"

PACKAGES = ("sol-svc-core", "sol-svc", "kafka-eio-service", "sol-worker", "sol-fn", "sol-obs", "sol-jobs", "sol-outbox", "sol-task")
CORE = "framework/ocaml/sol-svc-core/sol-svc-core.md"
SPECS = (SVC, CORE, KAFKA, WORKER, FN, OBS, JOBS, OUTBOX, TASK)

CASES = [
    ("a dropped Request.t field", "fail", SVC, "  ; trace_ctx : Obs_trace.t option\n", ""),
    ("a signature missing its result", "fail", KAFKA,
     "val config_of_env : unit -> (config, error) result", "val config_of_env : unit -> config"),
    ("a member the .mli does not export", "fail", SVC,
     "val internal_error  : string -> t", "val internal_error  : string -> t\nval not_implemented : t"),
    ("an old flat module name", "fail", KAFKA,
     "-> ?hooks:Kafka.Consumer.hooks",
     "-> ?hooks:Kafka_consumer.hooks"),
    ("a changed argument shape", "fail", KAFKA, "-> ?ot:Obs_eio.t", "-> ?ot:Obs_eio.t option"),
    ("a spec that shows fewer declarations than the .mli", "pass", SVC,
     "val query_params : t -> string -> string list", ""),
    ("an fn `Make.run` that predates the timed environment", "fail", FN,
     "    :  env:(_, _, _, _) Sol_env.timed\n", "    :  env:< net : _ Eio.Net.t; .. >\n"),
    ("a variant whose first constructor lost its leading bar", "fail", FN,
     "type trigger =\n  | Cron\n  | Lambda\n", "type trigger = Cron | Lambda\n"),
    ("a re-export that lost a constructor", "fail", OBS, "  | Warn\n", ""),
    ("an enqueue that predates the dedupe key", "fail", JOBS, "    -> ?dedupe_key:string\n", ""),
    ("a run that predates the retention arguments", "fail", JOBS, "    -> ?terminal_retention_s:float\n", ""),
    ("a relay that predates the batch argument", "fail", OUTBOX, "    -> ?batch:int\n", ""),
    ("a section the manifest neither maps nor excludes", "fail", WORKER,
     "## Entrypoints\n", "## Extra API\n\n```ocaml\nval extra : unit\n```\n\n## Entrypoints\n"),
    ("an exclusion that names a section the spec no longer carries", "fail", WORKER,
     "```ocaml\nmodule NotifyWorker", "```text\nmodule NotifyWorker"),
    (
        "a protected sol-task declaration removed",
        "fail",
        TASK,
        "type outcome =\n  | Ack            (* the side effect committed *)\n  | Retry of string (* leave the task eligible for redelivery *)\n",
        "",
    ),
    ("a sol-task outcome type renamed", "fail", TASK, "type outcome =\n", "type result =\n"),
    (
        "a sol-task constructor changed",
        "fail",
        TASK,
        "  | Retry of string (* leave the task eligible for redelivery *)",
        "  | Retry of string option (* leave the task eligible for redelivery *)",
    ),
]


def verdict(root):
    return subprocess.run([sys.executable, str(GUARD), "--root", str(root)], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        for package in PACKAGES:
            shutil.copytree(REPO / "framework/ocaml" / package, root / "framework/ocaml" / package)
        originals = {rel: (root / rel).read_text() for rel in SPECS}
        if verdict(root).returncode != 0:
            sys.exit(f"  [FAIL] the committed specs should pass\n{verdict(root).stdout}")
        print("  [OK]   the committed specs pass")
        for what, want, rel, old, new in CASES:
            text = originals[rel]
            if old not in text:
                sys.exit(f"  [FAIL] the fixture moved; update this test: {old!r} is not in {rel}")
            (root / rel).write_text(text.replace(old, new, 1))
            got = "pass" if verdict(root).returncode == 0 else "fail"
            (root / rel).write_text(text)
            if got != want:
                sys.exit(f"  [FAIL] {what}: expected {want}, got {got}")
            print(f"  [OK]   {what} {'passes' if want == 'pass' else 'is refused'}")
        if verdict(root).returncode != 0:
            sys.exit("  [FAIL] the committed specs should pass again")
        print("  [OK]   the committed specs again passes")
    print("framework doc signature guard: all expectations hold.")


main()

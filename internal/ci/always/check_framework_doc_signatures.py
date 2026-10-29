import os
import sys

if len(sys.argv) > 2 and sys.argv[1] == "--root":
    os.chdir(sys.argv[2])
else:
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))

import re, sys, pathlib
MANIFEST = [
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Auth`", ["framework/ocaml/sol-svc-core/lib/auth.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Peer`", ["framework/ocaml/sol-svc/lib/peer.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Route`", ["framework/ocaml/sol-svc/lib/route.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Request`", ["framework/ocaml/sol-svc/lib/request.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Response`", ["framework/ocaml/sol-svc/lib/response.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Service`", ["framework/ocaml/sol-svc/lib/service.mli"]),
    ("framework/ocaml/sol-svc-core/sol-svc-core.md", "## Public API", ["framework/ocaml/sol-svc-core/lib/auth.mli"]),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Configuration", ["framework/ocaml/kafka-eio-service/lib/kafka_service.mli"]),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Public API", ["framework/ocaml/kafka-eio-service/lib/kafka_service.mli"]),
    ("framework/ocaml/sol-worker/sol-worker.md", "## Module types", ["framework/ocaml/sol-worker/lib/worker.mli"]),
    ("framework/ocaml/sol-worker/sol-worker.md", "## Entrypoints", ["framework/ocaml/sol-worker/lib/worker.mli"]),
    ("framework/ocaml/sol-fn/sol-fn.md", "## Module type", ["framework/ocaml/sol-fn/lib/fn.mli"]),
    ("framework/ocaml/sol-fn/sol-fn.md", "## Functor", ["framework/ocaml/sol-fn/lib/fn.mli"]),
    ("framework/ocaml/sol-obs/sol-obs.md", "## Public API", ["framework/ocaml/sol-obs/lib/sol_obs.mli"]),
    ("framework/ocaml/sol-jobs/sol-jobs.md", "## Entrypoint", ["framework/ocaml/sol-jobs/lib/sol_jobs.mli"]),
    ("framework/ocaml/sol-outbox/sol-outbox.md", "## Public API", ["framework/ocaml/sol-outbox/lib/sol_outbox.mli"]),
    ("framework/ocaml/sol-task/sol-task.md", "## The contract", ["framework/ocaml/sol-task/lib/sol_task.mli"]),
]

# A mapped section may show a subset of its .mli, but these declarations are the
# section's reason for existing. Their absence is a removed contract, not a
# smaller example.
REQUIRED = {
    ("framework/ocaml/sol-task/sol-task.md", "## The contract"): [("type", "outcome")],
}

EXCLUSIONS = [
    ("framework/ocaml/sol-svc/sol-svc.md", "## Runtime Loop", "the server's implementation sketch, not a declaration the package owns"),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Test Plan", "a sketch of a test, not a declaration"),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Example Usage", "an application example"),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Message Contract", "an application's own MESSAGE module, not the package's declaration surface"),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Wire Format", "a wire-format illustration rather than a declaration"),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Example: Payments Producer", "an application example"),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Example: Audit Consumer", "an application example"),
    ("framework/ocaml/sol-worker/sol-worker.md", "## Fail stops the consumer", "an application's handler, not the package's declaration surface"),
    ("framework/ocaml/sol-worker/sol-worker.md", "## Usage examples", "an application example"),
    ("framework/ocaml/sol-worker/sol-worker.md", "## Test injection", "an example of calling For_testing, not a declaration"),
    ("framework/ocaml/sol-fn/sol-fn.md", "## Signature", "documents Obs_prometheus.push, which lives in the external obs-prometheus-eio package"),
    ("framework/ocaml/sol-fn/sol-fn.md", "## Generated main", "a scaffolded entrypoint example"),
    ("framework/ocaml/sol-obs/sol-obs.md", "## Example Usage", "an application example"),
    (
        "framework/ocaml/sol-jobs/sol-jobs.md",
        "## Module type",
        "the framework's JOB module type is a `module` declaration this check skips, and the section also carries an application's own `t` example",
    ),
    ("framework/ocaml/sol-jobs/sol-jobs.md", "## Deduplication: the Kafka → jobs handoff", "a call-site example"),
    ("framework/ocaml/sol-jobs/sol-jobs.md", "## Example: transactional enqueue", "an application example"),
    (
        "framework/ocaml/sol-task/sol-task.md",
        "## Local usage",
        "an application's task module and runtime invocation, not the package's declaration surface",
    ),
]

KEYWORDS = ("val", "type", "exception", "external", "module")


def strip_comments(s):
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\(\*.*?\*\)", " ", s, flags=re.S)
    return s


def norm(text):
    return re.sub(r"\s+", " ", strip_comments(text)).strip()


def declarations(text):
    """(keyword, name, normalised declaration text) for each declaration."""
    chunks, cur = [], None
    for raw in text.split("\n"):
        line = raw.strip()
        if not line:
            continue
        first = line.split()[0] if line.split() else ""
        if first in KEYWORDS and not line.startswith("|"):
            if cur:
                chunks.append(cur)
            cur = [line]
        elif cur is not None:
            if line == "end":
                chunks.append(cur)
                cur = None
                continue
            cur.append(line)
    if cur:
        chunks.append(cur)
    for chunk in chunks:
        joined = norm(" ".join(chunk))
        keyword = chunk[0].split()[0]
        rest = joined[len(keyword):].strip()
        name = re.split(r"[^A-Za-z0-9_']", rest, 1)[0] if rest else ""
        yield keyword, name, joined


def spec_declarations(md_text, heading):
    """Declarations inside ```ocaml blocks of one section (up to the next '## ')."""
    lines = md_text.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == heading)
    except StopIteration:
        print(f"✗ checker manifest names a section that does not exist: {heading}", file=sys.stderr)
        sys.exit(2)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    section = "\n".join(lines[start:end])
    out = []
    for block in re.findall(r"^```ocaml\n(.*?)^```", section, flags=re.S | re.M):
        for keyword, name, joined in declarations(block):
            if keyword == "module":
                continue
            out.append((keyword, name, joined))
    return out


def mli_declarations(paths):
    have = {}
    for path in paths:
        text = pathlib.Path(path).read_text()
        for keyword, name, joined in declarations(text):
            have.setdefault((keyword, name), []).append(joined)
    return have


def ocaml_sections(md_text):
    lines = md_text.split("\n")
    starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    starts.append(len(lines))
    for start, end in zip(starts, starts[1:]):
        if re.search(r"^```ocaml", "\n".join(lines[start:end]), flags=re.M):
            yield lines[start].strip()


problems = 0
for doc, heading, mlis in MANIFEST:
    have = mli_declarations(mlis)
    documented = spec_declarations(pathlib.Path(doc).read_text(), heading)
    for keyword, name in REQUIRED.get((doc, heading), []):
        if not any((k, n) == (keyword, name) for k, n, _ in documented):
            print(
                f"✗ {doc}: {heading} must document `{name}`, but does not"
            )
            problems += 1
    for keyword, name, joined in documented:
        key = (keyword, name)
        if key not in have:
            print(f"✗ {doc}: {heading} documents `{name}`, which {', '.join(mlis)} does not declare")
            print(f"    {joined[:160]}")
            problems += 1
        elif joined not in have[key]:
            print(f"✗ {doc}: {heading} shows a stale signature for `{name}`")
            print(f"    doc: {joined[:160]}")
            print(f"    mli: {have[key][0][:160]}")
            problems += 1

mapped = {(doc, heading) for doc, heading, _ in MANIFEST}
excluded = {(doc, heading) for doc, heading, _ in EXCLUSIONS}
sections = {
    doc: list(ocaml_sections(pathlib.Path(doc).read_text()))
    for doc in sorted({doc for doc, _, _ in MANIFEST + EXCLUSIONS})
}
for doc, doc_sections in sections.items():
    for heading in doc_sections:
        if (doc, heading) not in mapped and (doc, heading) not in excluded:
            print(f"✗ {doc}: {heading} carries an ocaml block but is neither a MANIFEST section nor a named EXCLUSION")
            problems += 1
for doc, heading, reason in EXCLUSIONS:
    if heading not in sections[doc]:
        print(f"✗ {doc}: EXCLUSIONS names {heading} as {reason!r}, which is not a section of the spec")
        problems += 1

if problems:
    print("")
    print(f"✗ {problems} framework spec problem(s): a stale signature, a section that is neither mapped nor excluded, or an exclusion that names no section.")
    sys.exit(1)
print(f"framework doc signatures: {len(MANIFEST)} mapped section(s) match their .mli, and every ocaml-bearing section is mapped or excluded.")

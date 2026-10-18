import re
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import hcl2
except ImportError:
    sys.exit(
        "python-hcl2 is not installed: pip install -r internal/ci/requirements.txt"
    )

_OPTIONS = hcl2.SerializationOptions(with_comments=False)


def unquote(value):
    if isinstance(value, str) and len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def is_string_literal(value):
    return isinstance(value, str) and len(value) >= 2 and value[0] == value[-1] == '"'


def variable_reference(value):
    match = re.fullmatch(r"\$\{var\.([A-Za-z0-9_]+)\}", value) if isinstance(value, str) else None
    return match.group(1) if match else None


def blocks(body, name):
    value = body.get(name, [])
    return value if isinstance(value, list) else [value]


@dataclass
class Resource:
    kind: str
    type: str
    name: str
    body: dict
    path: Path
    line: int
    module_address: str = ""
    indexed_module: bool = False

    @property
    def address(self):
        prefix = "data." if self.kind == "data" else ""
        return f"{self.module_address}{prefix}{self.type}.{self.name}"

    @property
    def where(self):
        return f"{self.path}:{self.line}"


def _header_line(text, kind, type_, name):
    pattern = rf'^\s*{kind}\s+"{re.escape(type_)}"\s+"{re.escape(name)}"'
    match = re.search(pattern, text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def load(path):
    path = Path(path)
    with open(path, encoding="utf-8") as f:
        return hcl2.load(f, serialization_options=_OPTIONS)


def resources(path, kinds=("resource", "data")):
    path = Path(path)
    doc = load(path)
    text = path.read_text(encoding="utf-8")
    found = []
    for kind in kinds:
        for entry in doc.get(kind, []):
            for type_, named in entry.items():
                for name, body in named.items():
                    t, n = unquote(type_), unquote(name)
                    found.append(Resource(kind, t, n, body, path, _header_line(text, kind, t, n)))
    return found


def modules(path):
    path = Path(path)
    doc = load(path)
    text = path.read_text(encoding="utf-8")
    return [
        Resource("module", "module", unquote(name), body, path, _header_line_module(text, unquote(name)))
        for entry in doc.get("module", [])
        for name, body in entry.items()
    ]


def _header_line_module(text, name):
    match = re.search(rf'^\s*module\s+"{re.escape(name)}"', text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def variables(path):
    doc = load(path)
    return {
        unquote(name): body
        for entry in doc.get("variable", [])
        for name, body in entry.items()
    }


def attributes(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from attributes(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from attributes(v, key)


def native_resources(directory, *, boundary):
    """Read a shipped root and its local modules, preserving Terraform addresses.

    Remote modules remain their providers' contract; this is not terraform init or
    an inspection of user infrastructure. Reject unreadable local sources rather
    than treating an incomplete walk as complete coverage.
    """
    boundary = Path(boundary).resolve()

    def visit(directory, prefix, ancestors, indexed_module):
        directory = Path(directory).resolve()
        if not directory.is_relative_to(boundary):
            raise ValueError(f"local module {directory} is outside shipped assets {boundary}")
        if directory in ancestors:
            raise ValueError(f"cyclic local module reference to {directory}")
        files = sorted(directory.glob("*.tf"))
        if not files:
            raise ValueError(f"local Terraform directory {directory} has no .tf files")
        found = []
        for path in files:
            for resource in resources(path, kinds=("resource",)):
                resource.module_address = prefix
                resource.indexed_module = indexed_module
                found.append(resource)
            for module in modules(path):
                source = module.body.get("source")
                if not is_string_literal(source):
                    raise ValueError(f"{module.where}: module {module.name} has no literal source")
                source = unquote(source)
                if "${" in source or "%{" in source or not source:
                    raise ValueError(f"{module.where}: unsupported module source {source!r}")
                if source.startswith("/"):
                    raise ValueError(f"{module.where}: absolute local module source {source!r}")
                if not source.startswith(("./", "../")):
                    continue
                found.extend(visit(
                    directory / source,
                    f"{prefix}module.{module.name}.",
                    ancestors + (directory,),
                    indexed_module or "count" in module.body or "for_each" in module.body,
                ))
        return found

    return visit(directory, "", (), False)

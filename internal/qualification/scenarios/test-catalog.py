#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
catalog = json.loads((Path(__file__).parent / "catalog.json").read_text())
assert catalog["contract"] == "qualification-scenario/v1"
ids = set()
for scenario in catalog["scenarios"]:
    assert scenario["id"] not in ids, scenario["id"]
    ids.add(scenario["id"])
    assert scenario["providers"]
    assert scenario["execution"]
    assert scenario["evidence"] == "behavioral"
    for key in ("fixture", "harness"):
        if key in scenario:
            assert (root / scenario[key]).exists(), scenario[key]
    assert scenario["driver"] in ("scenario-runner", "provider-harness")
print("qualification scenario catalog is internally consistent")

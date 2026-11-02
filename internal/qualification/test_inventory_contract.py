#!/usr/bin/env python3
import copy
import unittest

import inventory_contract


def document(verdict="reconciled", rows=None, inventory=True, verification=True, unknowns=None):
    return {
        "schema": 1,
        "verdict": verdict,
        "coverage": {
            "inventory": {"complete": inventory},
            "verification": {"complete": verification},
        },
        "resources": rows or [],
        "unknowns": unknowns or [],
    }


def row(status="owned", recovery=None):
    return {
        "status": status,
        "recovery": recovery or {"disposition": "not_applicable"},
    }


class InventoryContractTest(unittest.TestCase):
    def test_clean_inventory_is_reconciled(self):
        errors, _ = inventory_contract.check(document(), "reconciled")
        self.assertEqual(errors, [])

    def test_reconciled_refuses_an_unrecorded_row(self):
        errors, _ = inventory_contract.check(
            document(rows=[row("unrecorded", {"disposition": "recoverable"})]),
            "reconciled",
        )
        self.assertTrue(any("unrecorded" in error for error in errors))

    def test_incomplete_is_not_reconciled(self):
        errors, summary = inventory_contract.check(
            document(verdict="incomplete", verification=False), "incomplete"
        )
        self.assertEqual(errors, [])
        self.assertFalse(summary["verification_complete"])

    def test_attention_requires_a_discrepancy(self):
        errors, _ = inventory_contract.check(
            document(verdict="attention_required", verification=False), "attention"
        )
        self.assertTrue(any("no confirmed discrepancy" in error for error in errors))

    def test_attention_accepts_a_missing_row(self):
        errors, _ = inventory_contract.check(
            document(verdict="attention_required", rows=[row("missing")]), "attention"
        )
        self.assertEqual(errors, [])

    def test_unknown_requires_unknowns(self):
        errors, _ = inventory_contract.check(
            document(verdict="unknown", inventory=False, verification=False), "unknown"
        )
        self.assertTrue(any("no unknowns" in error for error in errors))

    def test_unverified_is_not_a_presence_claim(self):
        errors, _ = inventory_contract.check(
            document(verdict="unverified", verification=False), "unverified"
        )
        self.assertEqual(errors, [])

    def test_invalid_status_is_refused(self):
        bad = document()
        bad["resources"] = [copy.deepcopy(row("made_up"))]
        errors, _ = inventory_contract.check(bad, None)
        self.assertTrue(any("unknown resource status" in error for error in errors))


if __name__ == "__main__":
    unittest.main()

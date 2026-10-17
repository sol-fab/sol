#!/usr/bin/env python3
"""Regression tests for the shared transaction evidence predicate.

The predicate is what lets the row declare a worker effect. Its failure modes
are the point: malformed JSON, a missing or empty identity, an identity that is
only a substring of the read-back, an unrelated operation, and a read-back that
is the wrong shape must never establish success, while an exact matching effect
must. Both the in-cluster Job-log path and the qualification-transport path
call the same functions, and the command-line exit codes are pinned so the shell
callers cannot turn a parse failure into a pass.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

import transaction

HERE = pathlib.Path(__file__).resolve().parent
checks = 0
failures = 0


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def refuses(label: str, call, *args) -> None:
    try:
        call(*args)
    except transaction.EvidenceError:
        check(label, True)
    else:
        check(label, False)


def run(*argv: str, body: str = "") -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(HERE / "transaction.py"), *argv],
        input=body,
        capture_output=True,
        text=True,
    )


def test_charge_identity() -> None:
    check("charge id is read from a typed object", transaction.charge_id('{"id":"ch_1"}') == "ch_1")
    refuses("an empty charge id is refused", transaction.charge_id, '{"id":""}')
    refuses("a missing charge id is refused", transaction.charge_id, '{"accepted":true}')
    refuses("a non-string charge id is refused", transaction.charge_id, '{"id":5}')
    refuses("a non-object charge response is refused", transaction.charge_id, '["ch_1"]')
    refuses("malformed charge JSON is refused", transaction.charge_id, "not json")


def test_charge_effect() -> None:
    check(
        "an exact charge effect is visible",
        transaction.charge_effect_visible('[{"charge_id":"ch_1"}]', "ch_1"),
    )
    check(
        "alternate JSON whitespace still matches",
        transaction.charge_effect_visible('[ { "charge_id" : "ch_1" } ]', "ch_1"),
    )
    check(
        "a different charge is not the effect",
        not transaction.charge_effect_visible('[{"charge_id":"ch_2"}]', "ch_1"),
    )
    check(
        "a longer id is not a substring match",
        not transaction.charge_effect_visible('[{"charge_id":"ch_10"}]', "ch_1"),
    )
    check("an empty read-back is not the effect", not transaction.charge_effect_visible("[]", "ch_1"))
    check(
        "a non-string charge id is not the effect",
        not transaction.charge_effect_visible('[{"charge_id":5}]', "ch_1"),
    )
    refuses(
        "a non-array read-back is refused",
        transaction.charge_effect_visible,
        '{"charge_id":"ch_1"}',
        "ch_1",
    )
    refuses("malformed read-back JSON is refused", transaction.charge_effect_visible, "nope", "ch_1")


def test_order_identity() -> None:
    check(
        "order id is read from a typed object",
        transaction.order_id('{"order_id":"ord-1","status":"pending"}') == "ord-1",
    )
    check(
        "order id is read from a differently ordered object",
        transaction.order_id('{"status":"pending","order_id":"ord-1"}') == "ord-1",
    )
    check(
        "order id is read from an object with alternate whitespace",
        transaction.order_id('{ "order_id" : "ord-1" , "status" : "pending" }') == "ord-1",
    )
    refuses("an empty order id is refused", transaction.order_id, '{"order_id":""}')
    refuses("a missing order id is refused", transaction.order_id, '{"status":"pending"}')
    refuses("malformed order JSON is refused", transaction.order_id, "{")


def test_order_effect() -> None:
    def visible(body: str) -> bool:
        return transaction.order_effect_visible(body, "ord-1")

    check("fulfilled is a success status", visible('{"order_id":"ord-1","status":"fulfilled"}'))
    check("confirmed is a success status", visible('{"order_id":"ord-1","status":"confirmed"}'))
    check(
        "alternate JSON whitespace still matches",
        visible('{ "status" : "confirmed" , "order_id" : "ord-1" }'),
    )
    check(
        "differently ordered fields still match",
        visible('{"status":"fulfilled","order_id":"ord-1"}'),
    )
    check("pending is not a success status", not visible('{"order_id":"ord-1","status":"pending"}'))
    check("a different order is not the effect", not visible('{"order_id":"ord-2","status":"fulfilled"}'))
    check("a longer order id is not a substring match", not visible('{"order_id":"ord-10","status":"fulfilled"}'))
    check("a missing order id is not the effect", not visible('{"status":"fulfilled"}'))
    check("an order id only in an error field is not the effect", not visible('{"error":"order ord-1 rejected"}'))
    check("a missing status is not the effect", not visible('{"order_id":"ord-1"}'))
    check("a non-string status is not the effect", not visible('{"order_id":"ord-1","status":5}'))
    refuses("malformed order read-back is refused", transaction.order_effect_visible, "nope", "ord-1")
    refuses(
        "a non-object order read-back is refused",
        transaction.order_effect_visible,
        '["ord-1"]',
        "ord-1",
    )


def test_command_line_contract() -> None:
    result = run("charge-id", body='{"id":"ch_9"}')
    check("charge-id succeeds on a typed identity", result.returncode == 0 and result.stdout.strip() == "ch_9")
    check("charge-id fails on malformed JSON", run("charge-id", body="no").returncode == 2)
    check("charge-id fails on an empty identity", run("charge-id", body='{"id":""}').returncode == 2)
    check(
        "charge-effect succeeds on an exact match",
        run("charge-effect", "ch_9", body='[{"charge_id":"ch_9"}]').returncode == 0,
    )
    check(
        "charge-effect reports no match distinctly",
        run("charge-effect", "ch_9", body='[{"charge_id":"other"}]').returncode == 1,
    )
    check(
        "charge-effect refuses malformed evidence",
        run("charge-effect", "ch_9", body="no").returncode == 2,
    )
    result = run("order-id", body='{"status":"pending","order_id":"ord-9"}')
    check(
        "order-id succeeds on a typed identity",
        result.returncode == 0 and result.stdout.strip() == "ord-9",
    )
    check("order-id fails on malformed JSON", run("order-id", body="{").returncode == 2)
    check(
        "order-id refuses a response whose id is only in an error message",
        run("order-id", body='{"error":"order ord-9 was rejected"}').returncode == 2,
    )
    check(
        "order-effect succeeds on a matching success status",
        run("order-effect", "ord-9", body='{"order_id":"ord-9","status":"confirmed"}').returncode == 0,
    )
    check(
        "order-effect reports an unmet effect distinctly",
        run("order-effect", "ord-9", body='{"order_id":"ord-9","status":"pending"}').returncode == 1,
    )
    check(
        "order-effect refuses malformed evidence",
        run("order-effect", "ord-9", body="not-json").returncode == 2,
    )
    check("an unknown command fails", run("nonsense").returncode == 2)


def main() -> int:
    print("transaction evidence predicate")
    test_charge_identity()
    test_charge_effect()
    test_order_identity()
    test_order_effect()
    test_command_line_contract()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

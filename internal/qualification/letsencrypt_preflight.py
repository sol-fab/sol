#!/usr/bin/env python3
"""Best-effort Let's Encrypt duplicate-certificate preflight.

Let's Encrypt does not expose a remaining-quota API. Certificate Transparency
logs are the only public evidence of recent issuance, and they can lag. This
check refuses to start a production-issuer campaign when CT already shows the
duplicate-certificate limit reached, or when CT cannot be read. It is a
preflight, not an authoritative reservation: a successful check does not
guarantee the CA will issue.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request


LIMIT = 5
WINDOW = dt.timedelta(days=7)
HOST_PREFIXES = ("argocd", "grafana")


def default_ledger() -> str:
    root = os.environ.get("XDG_DATA_HOME")
    if root:
        return str(pathlib.Path(root) / "sol" / "qualification" / "letsencrypt-issuance.json")
    return str(pathlib.Path.home() / ".local" / "share" / "sol" / "qualification" / "letsencrypt-issuance.json")


def blocked_path(ledger: str | None) -> str | None:
    if not ledger:
        return None
    return str(pathlib.Path(ledger).with_name("letsencrypt-blocked.json"))


def blocked_until(path: str | None, host: str, now: dt.datetime) -> str | None:
    if not path or not os.path.exists(path):
        return None
    try:
        document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightError(f"rate-limit block {path} is unreadable: {error}") from error
    value = document.get(host) if isinstance(document, dict) else None
    if not isinstance(value, str):
        return None
    try:
        until = parse_time(value)
    except PreflightError:
        raise PreflightError(f"rate-limit block {path} has an invalid timestamp for {host}")
    return until.isoformat() if until > now else None


def record_block(path: str, hosts: list[str], retry_after: str) -> None:
    try:
        until = parse_time(retry_after)
    except PreflightError as error:
        raise PreflightError(f"--retry-after: {error}") from error
    target = pathlib.Path(path)
    document: dict[str, str] = {}
    if target.exists():
        try:
            loaded = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                document = {str(key): str(value) for key, value in loaded.items()}
        except (OSError, json.JSONDecodeError) as error:
            raise PreflightError(f"rate-limit block {path} is unreadable: {error}") from error
    for host in hosts:
        document[host] = until.isoformat()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def ledger_records(path: str, host: str, now: dt.datetime) -> list[str]:
    if not os.path.exists(path):
        return []
    try:
        document = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightError(f"issuance ledger {path} is unreadable: {error}") from error
    values = document.get(host, []) if isinstance(document, dict) else []
    if not isinstance(values, list):
        raise PreflightError(f"issuance ledger {path} has a non-list entry for {host}")
    recent = []
    for value in values:
        try:
            when = parse_time(str(value))
        except PreflightError:
            continue
        if now - when <= WINDOW:
            recent.append(when.isoformat())
    return recent


def reserve(path: str, host: str, now: dt.datetime) -> None:
    target = pathlib.Path(path)
    document: dict[str, list[str]] = {}
    if target.exists():
        try:
            loaded = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                document = {str(key): list(value) for key, value in loaded.items() if isinstance(value, list)}
        except (OSError, json.JSONDecodeError) as error:
            raise PreflightError(f"issuance ledger {path} is unreadable: {error}") from error
    document.setdefault(host, []).append(now.isoformat())
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(target)


class PreflightError(Exception):
    pass


def parse_time(value: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc)
    except ValueError:
        pass
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f"):
        try:
            return dt.datetime.strptime(value, fmt).replace(tzinfo=dt.timezone.utc)
        except ValueError:
            pass
    raise PreflightError(f"unexpected certificate timestamp {value!r}")


def issued_for(host: str, records: object, now: dt.datetime) -> list[str]:
    if not isinstance(records, list):
        raise PreflightError("crt.sh returned a non-list payload")
    serials: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            continue
        issuer = str(record.get("issuer_name") or "")
        if "Let's Encrypt" not in issuer:
            continue
        names = {
            line.strip().lower()
            for line in str(record.get("name_value") or "").splitlines()
            if line.strip()
        }
        if host.lower() not in names:
            continue
        not_before = str(record.get("not_before") or "")
        if not not_before or now - parse_time(not_before) > WINDOW:
            continue
        serial = str(record.get("serial_number") or "")
        if serial:
            serials.add(serial.lower())
    return sorted(serials)


def fetch(host: str, base: str, attempts: int = 3) -> object:
    url = f"{base.rstrip('/')}/?Identity={host}&output=json&exclude=expired"
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "sol-le-preflight/1"})
            with urllib.request.urlopen(request, timeout=25) as response:
                body = response.read()
            if not body.strip():
                return []
            return json.loads(body)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last = error
            time.sleep(2 * (attempt + 1))
    raise PreflightError(f"could not read CT history for {host}: {last}")


def check(
    base_domain: str,
    issuer: str,
    crt_sh_base: str,
    allow_unknown: bool,
    ledger: str | None = None,
    reserve_entry: bool = False,
) -> tuple[bool, list[str]]:
    if issuer != "letsencrypt-prod":
        return True, [f"issuer {issuer} is not letsencrypt-prod; ACME quota preflight skipped"]
    now = dt.datetime.now(dt.timezone.utc)
    lines: list[str] = []
    ok = True
    blocked = blocked_path(ledger)
    for prefix in HOST_PREFIXES:
        host = f"{prefix}.{base_domain}"
        try:
            until = blocked_until(blocked, host, now)
        except PreflightError as error:
            lines.append(f"FAIL {host}: {error}")
            ok = False
            continue
        if until:
            lines.append(f"FAIL {host}: Let's Encrypt rate-limited this exact set until {until}")
            ok = False
            continue
        try:
            records = fetch(host, crt_sh_base)
            serials = issued_for(host, records, now)
        except PreflightError as error:
            if allow_unknown:
                lines.append(f"WARN {host}: {error} (allowed by --allow-unknown)")
            else:
                lines.append(f"FAIL {host}: {error}")
                ok = False
            continue
        local = ledger_records(ledger, host, now) if ledger else []
        count = len(serials) + len(local)
        if local:
            lines.append(f"     {host}: {len(local)} local reservation(s), {len(serials)} CT certificate(s)")
        if count >= LIMIT:
            lines.append(f"FAIL {host}: {count} Let's Encrypt certificates in the last 168h (limit {LIMIT})")
            ok = False
        elif count == LIMIT - 1:
            lines.append(f"WARN {host}: {count} certificates in the last 168h; one duplicate slot remains")
        else:
            lines.append(f"OK   {host}: {count} Let's Encrypt certificate(s)/reservation(s) in the last 168h")
        if ok and reserve_entry and ledger:
            reserve(ledger, host, now)
    return ok, lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-domain", required=True)
    parser.add_argument("--issuer", default="")
    parser.add_argument("--crt-sh-base", default="https://crt.sh")
    parser.add_argument("--out")
    parser.add_argument("--ledger", default=default_ledger())
    parser.add_argument("--reserve", action="store_true")
    parser.add_argument("--allow-unknown", action="store_true")
    parser.add_argument("--record-block", action="store_true")
    parser.add_argument("--retry-after")
    args = parser.parse_args(argv[1:])
    if not args.record_block and not args.issuer:
        parser.error("--issuer is required unless --record-block is used")
    if args.record_block:
        if not args.retry_after:
            parser.error("--record-block requires --retry-after")
        hosts = [f"{prefix}.{args.base_domain}" for prefix in HOST_PREFIXES]
        target = blocked_path(args.ledger)
        if not target:
            parser.error("--record-block requires --ledger")
        try:
            record_block(target, hosts, args.retry_after)
        except PreflightError as error:
            print(f"letsencrypt-preflight: {error}", file=sys.stderr)
            return 1
        print(f"recorded rate-limit block until {args.retry_after} for {', '.join(hosts)}")
        return 0
    try:
        ok, lines = check(
            args.base_domain,
            args.issuer,
            args.crt_sh_base,
            args.allow_unknown,
            args.ledger,
            args.reserve,
        )
    except PreflightError as error:
        print(f"letsencrypt-preflight: {error}", file=sys.stderr)
        return 1
    report = "\n".join(lines) + "\n"
    print(report, end="")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(report)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

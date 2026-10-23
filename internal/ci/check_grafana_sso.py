#!/usr/bin/env python3
"""Fail if the platform's Grafana is not SSO-gated and anonymously closed.

This is a configuration invariant, not a claim that a live login worked. The
live qualification run is still required; this check prevents a future platform
change from silently restoring the old admin/admin, anonymous or no-OIDC shape.
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]


def fail(message):
    print(f"check_grafana_sso: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path):
    if not path.is_file():
        fail(f"{path} is missing")
    return path.read_text(encoding="utf-8")


def block(text, header):
    start = text.find(header)
    if start < 0:
        return None
    end = text.find("\n}", start)
    return text[start:end] if end >= 0 else text[start:]


def check_default_admin(path):
    text = read(path)
    block_text = block(text, 'variable "grafana_admin_password" {')
    if block_text is None:
        fail(f"{path} does not declare grafana_admin_password")
    if re.search(r'default\s*=\s*"admin"', block_text):
        fail(f"{path}: grafana_admin_password still defaults to admin")
    if not re.search(r"default\s*=\s*null", block_text):
        fail(f"{path}: grafana_admin_password must default to null (generated)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", help="repository root (default: this checkout)")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    module_path = root / "platform/cloud/modules/platform/main.tf"
    variables_path = root / "platform/cloud/modules/platform/variables.tf"
    roots = [
        root / "platform/cloud/aws/platform",
        root / "platform/cloud/gcp/platform",
    ]
    module = read(module_path)
    variables = read(variables_path)
    for path in [variables_path, *[r / "variables.tf" for r in roots]]:
        check_default_admin(path)

    if 'resource "random_password" "grafana_admin"' not in module:
        fail("the module does not generate the break-glass Grafana admin password")
    if 'resource "random_password" "grafana_secret_key"' not in module:
        fail("the module does not generate the Grafana session secret")
    if 'resource "terraform_data" "grafana_sso_validation"' not in module:
        fail("the module has no fail-closed Grafana SSO precondition")
    if not re.search(r"anonymous\s*=\s*\{[^}]*enabled\s*=\s*false", module, re.S):
        fail("Grafana anonymous access is not disabled")
    if not re.search(r"generic_oauth\s*=\s*\{[^}]*enabled\s*=\s*true", module, re.S):
        fail("Grafana generic_oauth is not enabled")
    for needle in [
        "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET",
        "GF_SECURITY_SECRET_KEY",
        "grafana-oidc",
        "grafana-security",
    ]:
        if needle not in module:
            fail(f"the Grafana Helm values do not reference {needle}")
    if "role_attribute_path" not in module:
        fail("the Grafana SSO config has no role mapping")
    if not re.search(r'variable "grafana_oidc_client_secret"[^}]*sensitive\s*=\s*true', variables, re.S):
        fail("grafana_oidc_client_secret is not marked sensitive")

    for root_dir in roots:
        main_tf = read(root_dir / "main.tf")
        root_vars = read(root_dir / "variables.tf")
        for name in [
            "grafana_oidc_client_id",
            "grafana_oidc_client_secret",
            "grafana_oidc_auth_url",
            "grafana_oidc_token_url",
            "grafana_oidc_api_url",
        ]:
            if f'variable "{name}"' not in root_vars:
                fail(f"{root_dir}/variables.tf does not declare {name}")
            if f"{name}" not in main_tf:
                fail(f"{root_dir}/main.tf does not pass {name} to the platform module")

    print(
        "check_grafana_sso: anonymous is off, generic OIDC is on, the client secret "
        "comes from the grafana-oidc Secret, the admin password is generated, and "
        "the module refuses to install Grafana without its SSO inputs"
    )


main()

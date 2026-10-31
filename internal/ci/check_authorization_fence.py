#!/usr/bin/env python3
"""The authorization fence is mandatory in the Terraform that creates it (DEC-062 rule 2).

DEC-062 permits exactly one identity to mutate workload authority: a reconciler
whose authority is fenced so that, even holding `iam:CreateRole`, it can only
create a Sol workload role under the environment's path with the boundary
attached, and can never replace that boundary or mutate an identity outside the
environment. On GCP the reconciler is limited to resource-scoped `setIamPolicy`
on Sol-managed secrets and creates no service accounts.

The fence's live behaviour is qualified separately (VERIF-021). This guard holds
the structural half so an edit that removes the condition, widens the resource,
drops the deny, or grants a service-account/role-creation permission fails here.
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

import tfconfig

AWS_ROOT = "platform/cloud/aws/authorization/main.tf"
GCP_ROOT = "platform/cloud/gcp/authorization/main.tf"
AWS_RECONCILER = "data.aws_iam_policy_document.reconciler"
GCP_ROLE = "google_project_iam_custom_role.authorization"
GCP_BINDING = "google_project_iam_member.reconciler_authorization"
BOUNDARY_REFERENCE = "policy/sol-${var.environment}-*-boundary"

FORBIDDEN_GCP_PREFIXES = ("iam.serviceAccounts.", "resourcemanager.projects.", "iam.roles.create")


def text(value):
    return tfconfig.unquote(value)


def string_list(container, key):
    raw = container.get(key, [])
    if isinstance(raw, str):
        raw = [raw]
    return [text(item) for item in raw]


def find(root, path, address, problems):
    file = root / path
    if not file.exists():
        problems.append(f"cannot read {path}")
        return None
    found = [r for r in tfconfig.resources(file) if r.address == address]
    if not found:
        problems.append(f"{path} has no {address}")
        return None
    return found[0]


def check_aws(root, problems):
    document = find(root, AWS_ROOT, AWS_RECONCILER, problems)
    if document is None:
        return
    allows_with_create = 0
    denies = set()
    for statement in tfconfig.blocks(document.body, "statement"):
        effect = text(statement.get("effect", ""))
        actions = string_list(statement, "actions")
        resources = string_list(statement, "resources")
        if effect == "Allow":
            for action in actions:
                if not action.startswith("iam:"):
                    continue
                if resources and all(resource == "*" for resource in resources):
                    problems.append(
                        f"the reconciler's Allow of {action} is not resource-scoped (resources = ['*'])"
                    )
                if "iam:CreateRole" == action:
                    allows_with_create += 1
                    conditions = tfconfig.blocks(statement, "condition")
                    boundary = any(
                        text(condition.get("variable", "")) == "iam:PermissionsBoundary"
                        and text(condition.get("test", "")) == "StringLike"
                        and any(
                            BOUNDARY_REFERENCE in value
                            for value in string_list(condition, "values")
                        )
                        for condition in conditions
                    )
                    if not boundary:
                        problems.append(
                            "the reconciler's `iam:CreateRole` Allow carries no StringEquals "
                            f"condition on iam:PermissionsBoundary = {BOUNDARY_REFERENCE}, so a "
                            "workload role could be created without the boundary"
                        )
                    scoped = any("role/" in resource and ("role_path" in resource or "sol/" in resource) for resource in resources)
                    if not scoped:
                        problems.append(
                            "the reconciler's `iam:CreateRole` Allow is not scoped to the environment's "
                            "role path"
                        )
        elif effect == "Deny":
            denies.update(actions)

    if allows_with_create == 0:
        problems.append("the reconciler has no `iam:CreateRole` Allow at all")
    for required in (
        "iam:DeleteRolePermissionsBoundary",
        "iam:PutRolePermissionsBoundary",
    ):
        if required not in denies:
            problems.append(
                f"the reconciler's policy does not deny {required}, so it could replace the boundary"
            )
    if not any(action.startswith("iam:CreateUser") or action.startswith("iam:CreatePolicy") for action in denies):
        problems.append(
            "the reconciler's policy does not deny identity creation outside the environment "
            "(no iam:CreateUser / iam:CreatePolicy deny)"
        )


def check_workload_trust(root, problems):
    """The workload trust must name the real EKS Pod Identity association ARN.

    The ARN has the standard EKS service and region segments:
    arn:aws:eks:<region>:<account>:podidentityassociation/<cluster>/<id>. An ARN with an
    empty service/region segment is a plausible-looking typo that denies every workload
    assume at runtime and is not caught by an IAM policy simulation (which checks the
    role policy, not the trust policy).
    """
    document = find(root, AWS_ROOT, "data.aws_iam_policy_document.workload_trust", problems)
    if document is None:
        return
    source_arns = []
    for statement in tfconfig.blocks(document.body, "statement"):
        for condition in tfconfig.blocks(statement, "condition"):
            if text(condition.get("variable", "")) == "aws:SourceArn":
                source_arns.extend(string_list(condition, "values"))
    if not source_arns:
        problems.append("the workload trust has no aws:SourceArn condition")
        return
    for arn in source_arns:
        if not arn.startswith("arn:aws:eks:") or ":podidentityassociation/" not in arn:
            problems.append(
                "the workload trust aws:SourceArn is not the standard EKS Pod Identity "
                f"association ARN (got {arn!r})"
            )


def check_gcp(root, problems):
    role = find(root, GCP_ROOT, GCP_ROLE, problems)
    if role is not None:
        permissions = string_list(role.body, "permissions")
        for permission in permissions:
            if permission.startswith(FORBIDDEN_GCP_PREFIXES):
                problems.append(
                    f"the GCP reconciler role grants {permission}, which is outside resource-scoped "
                    "secret grant authority"
                )
        if "secretmanager.secrets.setIamPolicy" not in permissions:
            problems.append(
                "the GCP reconciler role cannot set a secret grant "
                "(secretmanager.secrets.setIamPolicy is absent)"
            )

    binding = find(root, GCP_ROOT, GCP_BINDING, problems)
    if binding is not None:
        conditions = tfconfig.blocks(binding.body, "condition")
        scoped = any(
            "secrets/" in text(condition.get("expression", ""))
            and (
                "secret_prefix" in text(condition.get("expression", ""))
                or "sol-" in text(condition.get("expression", ""))
            )
            for condition in conditions
        )
        if not scoped:
            problems.append(
                "the GCP reconciler's role binding carries no condition limiting it to the "
                "environment's Sol-managed secrets"
            )


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems = []
    check_aws(root, problems)
    check_workload_trust(root, problems)
    check_gcp(root, problems)
    if problems:
        for problem in problems:
            print(f"check_authorization_fence: {problem}", file=sys.stderr)
        sys.exit(1)
    print(
        "check_authorization_fence: the AWS reconciler may create roles only under the "
        "environment path with the boundary and cannot mutate identity, and the GCP reconciler "
        "is limited to resource-scoped secret grants"
    )


if __name__ == "__main__":
    main()

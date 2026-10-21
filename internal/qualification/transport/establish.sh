#!/usr/bin/env bash
set -euo pipefail

cluster="${1:?usage: establish.sh <cluster-name> <iam-role-name> [region] [namespace]}"
role="${2:?usage: establish.sh <cluster-name> <iam-role-name> [region] [namespace]}"
region="${3:-us-east-1}"
verify_ns="${4:-default}"
if [ "$#" -ge 4 ]; then shift 4; else shift "$#"; fi
observe_ns=("$verify_ns" "$@")

account="$(aws sts get-caller-identity --query Account --output text)"
arn="arn:aws:iam::${account}:role/${role}"
cluster_arn="arn:aws:eks:${region}:${account}:cluster/${cluster}"
alias="${cluster}-qualifier"
here="$(cd "$(dirname "$0")" && pwd)"

echo "qualification transport: cluster=${cluster} role=${role} region=${region} namespace=${verify_ns}"

if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
  trust="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${account}:root\"},\"Action\":\"sts:AssumeRole\"}]}"
  aws iam create-role \
    --role-name "$role" \
    --description "Sol qualification-only transport principal (DEC-039). Not production." \
    --assume-role-policy-document "$trust" >/dev/null
  echo "  created IAM role ${role}"
else
  echo "  IAM role ${role} already exists"
fi

aws_authority_is_declared() {
  local attached
  attached="$(aws iam list-attached-role-policies \
    --role-name "$role" \
    --query 'length(AttachedPolicies)' \
    --output text)"
  if [ "$attached" != 0 ]; then
    echo "  the transport role carries ${attached} attached policy/policies beside its own inline policy, so its AWS authority is broader than this script declares; detach them and run again" >&2
    return 1
  fi
  local trust
  trust="$(aws iam get-role --role-name "$role" --query 'Role.AssumeRolePolicyDocument' --output json)"
  case "$trust" in
    *"arn:aws:iam::${account}:root"*) : ;;
    *)
      echo "  the transport role is not assumable by this account's root, so it is not the principal this script declares: ${trust}" >&2
      return 1
      ;;
  esac
  case "$trust" in
    *'"*"'* | *'"Service"'*)
      echo "  the transport role's trust policy names a principal beyond this account's root: ${trust}" >&2
      return 1
      ;;
  esac
  return 0
}

aws_authority_is_declared

aws iam put-role-policy \
  --role-name "$role" \
  --policy-name sol-qualifier-transport \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ReachTheCluster\",\"Effect\":\"Allow\",\"Action\":\"eks:DescribeCluster\",\"Resource\":\"${cluster_arn}\"}]}" >/dev/null
echo "  policy sol-qualifier-transport attached (eks:DescribeCluster on ${cluster_arn})"

entry_exists() {
  aws eks describe-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1
}

ensure_narrow_entry() {
  if entry_exists; then
    echo "  access entry already exists"
    return 0
  fi
  if ! aws eks create-access-entry \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --kubernetes-groups sol:qualifiers >/dev/null; then
    echo "  aws eks create-access-entry failed for ${arn}" >&2
    return 1
  fi
  echo "  created access entry with group sol:qualifiers"
}

remove_entry() {
  if ! aws eks delete-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1; then
    echo "  aws eks delete-access-entry failed for ${arn}" >&2
    return 1
  fi
  if entry_exists; then
    echo "  the access entry for ${arn} is still present after a delete that reported success" >&2
    return 1
  fi
  return 0
}

recreate_narrow_entry() {
  remove_entry || return 1
  if ! aws eks create-access-entry \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --kubernetes-groups sol:qualifiers >/dev/null; then
    echo "  aws eks create-access-entry failed for ${arn}" >&2
    return 1
  fi
  return 0
}

kubeconfig() {
  aws eks update-kubeconfig --name "$cluster" --alias "$alias" --role-arn "$arn" >/dev/null 2>&1
}

# The operator sees the class; the server's own words go to the evidence store.
# A refusal names identities and resources, and a terminal or CI log is read by
# more people than the run's evidence directory is. The class is derived from the
# status the server returned, and the text it was derived from is retained beside
# it so the classification stays auditable rather than becoming a claim.
classify_refusal() {
  case "$1" in
    *[Ff]orbidden*) echo rbac ;;
    *[Uu]nauthorized* | *"must be logged in"* | *"connection refused"* | *"no route to host"* | *"i/o timeout"* | *x509* | *"TLS handshake"*) echo endpoint ;;
    *"is invalid"* | *"validation failed"* | *"cannot unmarshal"* | *"unknown field"* | *BadRequest*) echo validation ;;
    *"already exists"* | *"has been modified"* | *"the object has been modified"*) echo conflict ;;
    *"too many requests"* | *"try again"* | *"service unavailable"* | *etcdserver* | *webhook*) echo transient ;;
    *) echo unknown ;;
  esac
}

retain_evidence() {
  local name="${1:?retain_evidence needs a basename}" text="$2" dir="${SOL_TRANSPORT_EVIDENCE_DIR:-}"
  if [ -z "$dir" ]; then
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sol-transport-evidence.XXXXXX")"
  fi
  if ! printf '%s\n' "$text" >"${dir}/${name}"; then
    echo "  the evidence ${name} could not be written to ${dir}; refusing to continue without it" >&2
    exit 1
  fi
  echo "$name"
}

end_state=narrow

lost_authority() {
  echo "  establishment_window: open (the cluster-admin association may still be in place)" >&2
  echo "  COULD NOT establish that ${arn} holds only the declared transport on ${cluster}." >&2
  echo "  It may still carry the temporary cluster-admin association. Remove the access entry by hand" >&2
  echo "  before using this cluster, and treat the transport as unestablished:" >&2
  echo "    aws eks delete-access-entry --cluster-name ${cluster} --principal-arn ${arn}" >&2
  exit 1
}

cleanup() {
  case "$end_state" in
    narrow)
      if ! recreate_narrow_entry; then
        echo "  the window could not be closed by recreating the entry; removing it instead" >&2
        remove_entry || lost_authority
        echo "  the access entry is gone (describe-access-entry reports it absent): ${arn} holds no entry on ${cluster}" >&2
      fi
      ;;
    none)
      echo "  removing the access entry for ${arn}" >&2
      remove_entry || lost_authority
      echo "  the access entry is gone (describe-access-entry reports it absent): ${arn} holds no entry on ${cluster}" >&2
      ;;
  esac
  echo "  establishment_window: closed (${arn} holds no cluster-admin association on ${cluster})" >&2
}
trap cleanup EXIT
# A SIGTERM or SIGHUP runs this EXIT trap, so a cancelled run still closes the
# window and says so; the stub suite pins that. SIGKILL cannot be trapped, so no
# code here runs after it, and the association it leaves behind is only readable
# from the provider -- tracked separately, not claimed here.

ensure_narrow_entry

admin_policy="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

# A run killed with SIGKILL cannot execute its EXIT trap, so the association it
# opened is still in place when the next establishment starts. Nothing else reads it:
# the teardown inventory has no access-entry class. A later successful run recreates
# the narrow entry anyway, so the window gets closed either way -- but silently, and
# only if a later run happens. Saying what was found is the difference between a
# repaired window and an invisible one.
left_open_policies() {
  aws eks list-associated-access-policies --cluster-name "$cluster" --region "$region" \
    --principal-arn "$arn" --query 'associatedAccessPolicies[].policyArn' --output text 2>/dev/null
}

left_open="$(left_open_policies)" || left_open=""
case "$left_open" in
  *AmazonEKSClusterAdminPolicy*)
    # Named, not summarised: which principal, which policy, how many. "repaired"
    # alone hides what was found and cannot be audited later. This is a repair of a
    # real security state, so it says what the state was; `open` on failure stays P0
    # and is never converted into this.
    left_open_count="$(printf '%s\n' "$left_open" | tr ' \t' '\n\n' | grep -c 'AmazonEKSClusterAdminPolicy')"
    echo "  a previous run left ${left_open_count} cluster-admin association(s) on ${arn} (policy ${admin_policy}); closing before opening a new window" >&2
    recreate_narrow_entry || lost_authority
    echo "  establishment_window: repaired (principal ${arn}, policy ${admin_policy}, ${left_open_count} association(s) left open by an earlier run, now closed)" >&2
    ;;
esac

echo "  opening a temporary establishment window (cluster-admin association)"
aws eks associate-access-policy \
  --cluster-name "$cluster" \
  --principal-arn "$arn" \
  --policy-arn "$admin_policy" \
  --access-scope type=cluster >/dev/null

apply_output=""
for _ in 1 2 3 4 5 6; do
  kubeconfig
  if apply_output="$(kubectl --context "$alias" apply -f "$here/transport.yaml" 2>&1 >/dev/null)"; then
    break
  fi
  sleep 10
done

get_output=""
if ! get_output="$(kubectl --context "$alias" get clusterrole sol-qualifier-transport 2>&1 >/dev/null)"; then
  # Either the apply or the read that confirms it refused. Both are captured, so a
  # refusal from the confirming read is classified rather than lost.
  refusal="${apply_output:-${get_output:-<kubectl produced no output>}}"
  evidence="$(retain_evidence transport-refusal.txt "$refusal")"
  echo "  could not apply the transport manifest" >&2
  echo "  error_class: $(classify_refusal "$refusal")" >&2
  echo "  the refused output is retained in the evidence beside this log, not printed: ${evidence}" >&2
  exit 1
fi

# The observation reads are namespace-scoped: the reusable ClusterRole is bound
# only in the namespaces the CA family observes, and only while the temporary
# establishment window is open.
for ns in "${observe_ns[@]}"; do
  if ! kubectl --context "$alias" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sol-qualifier-observe
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sol-qualifier-observe
subjects:
  - kind: Group
    name: sol:qualifiers
    apiGroup: rbac.authorization.k8s.io
EOF
  then
    echo "  could not bind the observation reads in ${ns}" >&2
    exit 1
  fi
done

echo "  closing the window by deleting the access entry and recreating it with only sol:qualifiers"
recreate_narrow_entry

end_state=none

can_i() {
  local verb="$1" resource="$2" subresource="${3:-}"
  if [ -n "$subresource" ]; then
    kubectl --context "$alias" auth can-i "$verb" "$resource" --subresource="$subresource" -n "$verify_ns" 2>/dev/null
  else
    kubectl --context "$alias" auth can-i "$verb" "$resource" -n "$verify_ns" 2>/dev/null
  fi
}

secrets_verdict() {
  kubeconfig
  local out status=0 verdict evidence
  out="$(kubectl --context "$alias" get secrets -n "$verify_ns" 2>&1)" || status=$?
  if [ "$status" = 0 ]; then
    verdict=answered
  else
    case "$out" in
      *[Ff]orbidden* | *[Uu]nauthorized*) verdict=denied ;;
      *) verdict=unobservable ;;
    esac
  fi
  # The listing is the proof, not the report: a too-broad grant answers with
  # secret names, and those belong in the evidence store, not in the run log.
  evidence="$(retain_evidence transport-secrets.txt "${out:-<no output>}")"
  echo "get secrets -n ${verify_ns}: ${verdict} (retained in evidence, not printed: ${evidence})"
  if [ "$verdict" = denied ]; then
    return 0
  fi
  return 1
}

probe_effective_surface() {
  kubeconfig
  local whoami evidence
  whoami="$(kubectl --context "$alias" auth whoami -o json 2>/dev/null || true)"
  case "$whoami" in
    *"assumed-role/${role}/"*) : ;;
    *)
      evidence="$(retain_evidence transport-whoami.txt "${whoami:-<no answer>}")"
      echo "  the context does not authenticate as ${role} (retained in evidence, not printed: ${evidence})" >&2
      return 1
      ;;
  esac
  # The most specific diagnosis first: a mapping that carries system:masters is the
  # finding, and it must be named even when the group check would also refuse it.
  case "$whoami" in
    *system:masters*)
      evidence="$(retain_evidence transport-whoami.txt "${whoami}")"
      echo "  the context carries system:masters, which is not the declared mapping (retained in evidence, not printed: ${evidence})" >&2
      return 1
      ;;
  esac
  case "$whoami" in
    *sol:qualifiers*) : ;;
    *)
      evidence="$(retain_evidence transport-whoami.txt "${whoami:-<no answer>}")"
      echo "  the context is not in the declared group sol:qualifiers (retained in evidence, not printed: ${evidence})" >&2
      return 1
      ;;
  esac
  if ! kubectl --context "$alias" get pods -n "$verify_ns" >/dev/null 2>&1; then
    echo "  the addressing grant is not effective: get pods -n ${verify_ns} was refused" >&2
    return 1
  fi
  local verdict rc=0
  verdict="$(secrets_verdict)" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "  the grant is not shown to be transport-only: ${verdict}" >&2
    return 1
  fi
  deny() {
    local verb="$1" resource="$2" subresource="${3:-}" verdict
    verdict="$(can_i "$verb" "$resource" "$subresource")"
    if [ "$verdict" != no ]; then
      echo "  the grant is broader than declared: auth can-i ${verb} ${resource}${subresource:+ --subresource=$subresource} -n ${verify_ns} did not answer no" >&2
      return 1
    fi
  }
  allow() {
    local verb="$1" resource="$2" subresource="${3:-}" verdict
    verdict="$(can_i "$verb" "$resource" "$subresource")"
    if [ "$verdict" != yes ]; then
      echo "  the declared grant is not effective: auth can-i ${verb} ${resource}${subresource:+ --subresource=$subresource} -n ${verify_ns} did not answer yes" >&2
      return 1
    fi
  }
  allow_in() {
    local ns="$1" verb="$2" resource="$3" verdict
    verdict="$(kubectl --context "$alias" auth can-i "$verb" "$resource" -n "$ns" 2>/dev/null)"
    if [ "$verdict" != yes ]; then
      echo "  the declared observation grant is not effective in ${ns}: auth can-i ${verb} ${resource} did not answer yes" >&2
      return 1
    fi
  }
  deny_in() {
    local ns="$1" verb="$2" resource="$3" subresource="${4:-}" verdict
    if [ -n "$subresource" ]; then
      verdict="$(kubectl --context "$alias" auth can-i "$verb" "$resource" --subresource="$subresource" -n "$ns" 2>/dev/null)"
    else
      verdict="$(kubectl --context "$alias" auth can-i "$verb" "$resource" -n "$ns" 2>/dev/null)"
    fi
    if [ "$verdict" != no ]; then
      echo "  the grant is broader than declared in ${ns}: auth can-i ${verb} ${resource}${subresource:+ --subresource=$subresource} did not answer no" >&2
      return 1
    fi
  }
  allow list services || return 1
  allow create pods portforward || return 1
  allow get namespaces || return 1
  for ns in "${observe_ns[@]}"; do
    allow_in "$ns" get deployments.apps || return 1
    allow_in "$ns" list deployments.apps || return 1
    allow_in "$ns" get jobs.batch || return 1
    allow_in "$ns" list configmaps || return 1
    allow_in "$ns" get configmaps || return 1
    deny_in "$ns" '*' '*' || return 1
    deny_in "$ns" create pods exec || return 1
    deny_in "$ns" get pods log || return 1
    deny_in "$ns" delete pods || return 1
    deny_in "$ns" get secrets || return 1
  done
  # A cluster-wide observation grant would answer yes here. It must not: the
  # observation reads are RoleBound only in the declared namespaces.
  local unbound="${SOL_QUALIFIER_UNBOUND_NS:-sol-qualifier-unbound}"
  deny_in "$unbound" get deployments.apps || return 1
  deny_in "$unbound" get jobs.batch || return 1
  deny_in "$unbound" get configmaps || return 1
  return 0
}

verify_attempts="${SOL_QUALIFIER_VERIFY_ATTEMPTS:-12}"
verify_interval="${SOL_QUALIFIER_VERIFY_INTERVAL_S:-15}"
case "$verify_attempts" in '' | *[!0-9]*)
  echo "  SOL_QUALIFIER_VERIFY_ATTEMPTS must be a positive integer" >&2
  exit 2
  ;;
esac
[ "$verify_attempts" -gt 0 ] || {
  echo "  SOL_QUALIFIER_VERIFY_ATTEMPTS must be a positive integer" >&2
  exit 2
}
case "$verify_interval" in '' | *[!0-9]*)
  echo "  SOL_QUALIFIER_VERIFY_INTERVAL_S must be a non-negative integer" >&2
  exit 2
  ;;
esac

verified=false
attempt=0
while [ "$attempt" -lt "$verify_attempts" ]; do
  attempt=$((attempt + 1))
  if probe_effective_surface; then
    verified=true
    break
  fi
  echo "  the effective surface is not yet the declared one; attempt ${attempt}/${verify_attempts}" >&2
  if [ "$attempt" -lt "$verify_attempts" ]; then
    sleep "$verify_interval"
  fi
done

if [ "$verified" != true ]; then
  echo "  refusing to leave a credential broader than its contract: removing the access entry" >&2
  exit 1
fi

end_state=narrow
trap - EXIT
echo "  verified the effective surface as ${role} in ${verify_ns}: pods and services readable, namespaces readable, deployments/jobs/configmaps readable in ${observe_ns[*]}, observation reads denied outside them, secrets denied, pods/portforward permitted, pods/exec, pods/log, delete pods and */* denied in every observation namespace"

echo "qualification transport established. Verify with:"
echo "  aws eks update-kubeconfig --name ${cluster} --alias ${alias} --role-arn ${arn}"
echo "  kubectl --context ${alias} get pods -n ${verify_ns}                                         # succeeds"
echo "  kubectl --context ${alias} get secrets -n ${verify_ns}                                      # denied"
echo "  kubectl --context ${alias} auth can-i create pods --subresource=portforward -n ${verify_ns}  # yes"
echo "  kubectl --context ${alias} auth can-i create pods --subresource=exec -n ${verify_ns}         # no"

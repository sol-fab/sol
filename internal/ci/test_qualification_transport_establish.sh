#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
establish="$repo/internal/qualification/transport/establish.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_QUALIFY_TEST_STATE:?}"
case "$1 $2" in
  "sts get-caller-identity") echo 111122223333 ;;
  "iam create-role" | "iam put-role-policy") : ;;
  "iam list-attached-role-policies")
    if [ -f "$state/attached" ]; then echo 1; else echo 0; fi
    ;;
  "iam get-role")
    if [ -f "$state/no-role" ]; then exit 254; fi
    if [ -f "$state/wildcard-trust" ]; then
      echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"}]}'
    elif [ -f "$state/extra-principal" ]; then
      echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["arn:aws:iam::111122223333:root","*"]},"Action":"sts:AssumeRole"}]}'
    else
      echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111122223333:root"},"Action":"sts:AssumeRole"}]}'
    fi
    ;;
  "eks describe-access-entry") [ -f "$state/entry" ] ;;
  "eks create-access-entry") touch "$state/entry" ;;
  "eks delete-access-entry")
    if [ -f "$state/delete-refused" ]; then exit 254; fi
    rm -f "$state/entry" "$state/wide"
    ;;
  "eks associate-access-policy") touch "$state/wide" "$state/associated" ;;
  "eks disassociate-access-policy") touch "$state/disassociated" ;;
  *) : ;;
esac
AWS

cat >"$work/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_QUALIFY_TEST_STATE:?}"
if [ "${1:-}" = "--context" ]; then shift 2; fi
wide() { [ -f "$state/wide" ]; }
case "$1" in
  apply)
    if [ -f "$state/apply-signals-parent" ]; then
      for _ in $(seq 1 500); do [ -s "$state/signal-target" ] && break; done
      kill -TERM "$(cat "$state/signal-target")" 2>/dev/null || true
      exit 1
    fi
    if [ -f "$state/apply-refused" ]; then
      echo 'Error from server (Forbidden): clusterroles.rbac.authorization.k8s.io is forbidden: User "arn:aws:sts::111122223333:assumed-role/sol-qualifier-transport/EKSGetTokenAuth" cannot create resource "clusterroles"' >&2
      exit 1
    fi
    wide || exit 1
    if [ -f "$state/apply-noop" ]; then exit 0; fi
    touch "$state/role"
    ;;
  get)
    case "$2" in
      clusterrole)
        if [ -f "$state/get-refuses" ]; then
          echo 'Error from server (Unauthorized): the server has asked for the client to provide credentials' >&2
          exit 1
        fi
        [ -f "$state/role" ]
        ;;
      pods) [ -f "$state/entry" ] && [ -f "$state/role" ] ;;
      secrets)
        if wide || [ -f "$state/residual" ]; then
          echo charge-svc-secrets
        else
          echo "Error from server (Forbidden): secrets is forbidden" >&2
          exit 1
        fi
        ;;
      *) : ;;
    esac
    ;;
  auth)
    case "$2" in
      whoami)
        if [ -f "$state/masters" ]; then
          echo '{"status":{"userInfo":{"username":"arn:aws:sts::111122223333:assumed-role/sol-qualifier-transport/EKSGetTokenAuth","groups":["system:masters","system:authenticated"]}}}'
        else
          echo '{"status":{"userInfo":{"username":"arn:aws:sts::111122223333:assumed-role/sol-qualifier-transport/EKSGetTokenAuth","groups":["sol:qualifiers","system:authenticated"]}}}'
        fi
        ;;
      can-i)
        { for arg in "$@"; do printf '<%s>' "$arg"; done; printf '\n'; } >>"$state/can-i.argv"
        case "${3:-}" in
          "" | *" "*)
            echo "error: you must specify two arguments: verb resource or verb resource/resourceName." >&2
            exit 1
            ;;
        esac
        case "${4:-}" in
          "" | -* | *" "*)
            echo "error: you must specify two arguments: verb resource or verb resource/resourceName." >&2
            exit 1
            ;;
        esac
        if wide; then echo yes; exit 0; fi
        if [ ! -f "$state/entry" ] || [ ! -f "$state/role" ]; then echo no; exit 0; fi
        case "$*" in
          *"list services"* | *"create pods --subresource=portforward"*) echo yes ;;
          *"get namespaces"*) echo yes ;;
          *"get deployments.apps"* | *"list deployments.apps"* | *"get jobs.batch"* | *"list configmaps"* | *"get configmaps"*)
            if [ -f "$state/observe-wide" ]; then echo yes; exit 0; fi
            case "$*" in
              *"-n pluto-payments"* | *"-n pluto-comms"*) echo yes ;;
              *) echo no ;;
            esac
            ;;
          *"create pods --subresource=exec"*)
            if [ -f "$state/exec" ]; then echo yes; else echo no; fi
            ;;
          *) echo no ;;
        esac
        ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
KUBECTL

chmod +x "$work/bin/aws" "$work/bin/kubectl"
# The establishment retry loop waits between attempts for an access entry to take
# effect. That wait is not what these cases test, so it must not spend it here.
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/sleep"
export PATH="$work/bin:$PATH"
export SOL_QUALIFY_TEST_STATE="$work/state"
export SOL_QUALIFIER_VERIFY_ATTEMPTS=2
export SOL_QUALIFIER_VERIFY_INTERVAL_S=0
export SOL_TRANSPORT_REFUSAL_EVIDENCE="$work/refusal.txt"

failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

reset_state() {
  rm -rf "$work/state"
  mkdir -p "$work/state"
}

run_establish() {
  if "$establish" sol-qual-cluster sol-qualifier-transport us-east-1 pluto-payments pluto-comms >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
}

expect_exit() {
  if [ "$status" = "$1" ]; then ok "$2"; else bad "$2 (observed exit $status)"; fi
}

expect_file() {
  if [ -f "$2" ]; then ok "$1"; else bad "$1"; fi
}

expect_failure() {
  if [ "$status" != 0 ]; then ok "$1"; else bad "$1 (observed exit 0)"; fi
}

expect_no_file() {
  if [ -f "$2" ]; then bad "$1"; else ok "$1"; fi
}

expect_text() {
  if grep -q "$1" "$work/out"; then ok "$2"; else bad "$2"; fi
}

expect_no_text() {
  if grep -q "$1" "$work/out"; then bad "$2"; else ok "$2"; fi
}

expect_evidence_text() {
  if [ -f "$SOL_TRANSPORT_REFUSAL_EVIDENCE" ] && grep -q "$1" "$SOL_TRANSPORT_REFUSAL_EVIDENCE"; then
    ok "$2"
  else
    bad "$2"
  fi
}

expect_argv_separated() {
  if grep -qF '<list><services>' "$work/state/can-i.argv" &&
    ! grep -qF '<list services>' "$work/state/can-i.argv"; then
    ok "$1"
  else
    bad "$1"
  fi
}

echo "establish: the surface it declares is the surface it verifies"
reset_state
run_establish
expect_exit 0 "a narrow end state is accepted"
expect_argv_separated "auth can-i receives the verb and resource as separate arguments"
expect_file "the run opened the establishment window" "$work/state/associated"
expect_file "the access entry remains" "$work/state/entry"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "verified the effective surface" "the verification is the reported evidence"
expect_text "deployments/jobs/configmaps readable" "the observation grants are part of the verified surface"
expect_text "observation reads denied outside them" "the unbound-namespace denial is part of the verified surface"

echo
echo "establish: an observation read outside the declared namespaces is refused"
reset_state
touch "$work/state/observe-wide"
run_establish
expect_exit 1 "a cluster-wide observation grant fails establishment"
expect_text "broader than declared in sol-qualifier-unbound" "the refusal names the unbound namespace"
expect_text "get deployments.apps" "the refusal names the observation read"

echo
echo "establish: a surface broader than declared is refused, and nothing broad is left behind"
reset_state
touch "$work/state/residual"
run_establish
expect_exit 1 "a residual broad grant fails establishment"
expect_no_file "the access entry is removed rather than left broad" "$work/state/entry"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "the grant is not shown to be transport-only" "the refusal names what it observed"

echo
echo "establish: a grant the declared contract excludes is refused, not sampled away"
reset_state
touch "$work/state/exec"
run_establish
expect_exit 1 "a residual pods/exec grant fails establishment"
expect_no_file "the access entry is removed rather than left broad" "$work/state/entry"
expect_text "auth can-i create pods --subresource=exec" "the refusal names the excluded verb and subresource"

echo
echo "establish: a mapping outside the declared group is refused"
reset_state
touch "$work/state/masters"
run_establish
expect_exit 1 "a system:masters mapping fails establishment"
expect_no_file "the access entry is removed rather than left broad" "$work/state/entry"
expect_text "system:masters" "the refusal names the mapping it saw"

echo
echo "establish: a manifest that did not take effect fails, with the window closed"
reset_state
touch "$work/state/apply-noop"
run_establish
expect_exit 1 "a transport that did not apply fails establishment"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "could not apply the transport manifest" "the failure names the manifest"
expect_text "establishment_window: closed" "the failure states the window was closed"

echo
echo "establish: a refused manifest reports its class, keeps the server's words in evidence only"
reset_state
rm -f "$SOL_TRANSPORT_REFUSAL_EVIDENCE"
touch "$work/state/apply-refused"
run_establish
expect_exit 1 "a refused transport manifest fails establishment"
expect_text "error_class: rbac" "the operator is told the refusal's class"
expect_text "establishment_window: closed" "the failure states the window was closed"
expect_no_text "Forbidden" "the printed output carries no server message"
expect_no_text "EKSGetTokenAuth" "the printed output carries no refused identity"
expect_evidence_text "Forbidden" "the evidence retains what the API server said"
expect_evidence_text "EKSGetTokenAuth" "the evidence retains the identity the cluster refused"
expect_no_text "$work/" "the printed output carries no absolute evidence path"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"

echo
echo "establish: a refusal from the confirming read is classified too, not lost"
reset_state
rm -f "$SOL_TRANSPORT_REFUSAL_EVIDENCE"
touch "$work/state/apply-noop" "$work/state/get-refuses"
run_establish
expect_exit 1 "a refusing confirming read fails establishment"
expect_text "error_class: endpoint" "the class comes from the read that refused"
expect_no_text "Unauthorized" "the printed output carries no server message"
expect_evidence_text "Unauthorized" "the evidence retains the confirming read's refusal"

echo
echo "establish: a termination while the window is open still closes it"
# Which of these discriminate: the two that read the close -- "the terminated run
# closed the cluster-admin window" and "the terminated run states the window was
# closed". Together they are what fails when the EXIT trap goes away. "Does not
# report success" is necessary but not discriminating: it passes at 143 (killed by
# SIGTERM) exactly as it would at 137 (SIGKILL), where no trap has run and nothing
# was closed, so it must not be read as coverage of the trap.
reset_state
touch "$work/state/apply-signals-parent"
"$establish" sol-qual-cluster sol-qualifier-transport us-east-1 pluto-payments pluto-comms \
  >"$work/out" 2>&1 &
signal_pid=$!
echo "$signal_pid" >"$work/state/signal-target"
if wait "$signal_pid"; then status=0; else status=$?; fi
expect_failure "a terminated establishment does not report success"
expect_no_file "the terminated run closed the cluster-admin window" "$work/state/wide"
expect_text "establishment_window: closed" "the terminated run states the window was closed"
expect_no_text "establishment_window: open" "the terminated run does not leave the window open"

echo
echo "establish: a removal that did not happen is reported, not assumed"
reset_state
touch "$work/state/delete-refused"
run_establish
expect_exit 1 "a refused delete fails establishment"
expect_file "the entry that survived is still there" "$work/state/entry"
expect_file "the wide association that survived is still there" "$work/state/wide"
expect_text "COULD NOT establish that" "the failure says the authority could not be shown to be gone"
expect_text "delete-access-entry --cluster-name sol-qual-cluster" "the failure says how to remove it"
expect_text "establishment_window: open" "the failure says the window may still be open"

echo
echo "establish: AWS authority beside the declared policy is refused before any window opens"
reset_state
touch "$work/state/attached"
run_establish
expect_exit 1 "an attached policy fails establishment"
expect_no_file "no establishment window was opened" "$work/state/associated"
expect_text "attached policy" "the refusal names the attached policy"

echo
echo "establish: a trust policy that does not name this account is refused before any window opens"
reset_state
touch "$work/state/wildcard-trust"
run_establish
expect_exit 1 "a trust policy naming a wildcard principal fails establishment"
expect_no_file "no establishment window was opened" "$work/state/associated"
expect_text "not assumable by this account's root" "the refusal names the trust policy"

echo
echo "establish: a trust policy naming a principal beyond this account is refused"
reset_state
touch "$work/state/extra-principal"
run_establish
expect_exit 1 "an extra trust principal fails establishment"
expect_no_file "no establishment window was opened" "$work/state/associated"
expect_text "beyond this account's root" "the refusal names the extra principal"

echo
if [ "$failures" -eq 0 ]; then
  echo "qualification transport establishment: every expectation held."
  exit 0
fi
echo "qualification transport establishment: $failures expectation(s) FAILED."
exit 1

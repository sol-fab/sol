# GCP CA observer exercise — 2026-10-21

Status: MECHANISM evidence on a disposable local cluster. Not a release verdict.

Candidate: `v0.1.0-alpha.43`, revision
`a7799b90041f29273219ceb2875eb195cbca327d`. Alpha.44 was not cut, so
alpha.43 is used as the obligation source and labelled mechanism-only here.

## Scope

**Application CA phase only.** The migration CA phase is not isolatable against
a synthetic Job: `qual_path.ml` `P.migration` calls `QME.run`, which runs the
verified candidate's own `migrate apply` and captures the executed Job locator
and execution receipt. A synthetic Job has no `MigrationExecution` receipt;
the phase would report a skip, not an observed execution. Migration CA
observation therefore remains campaign-only.

**Exercise-scoped observer.** The exercise creates its own ServiceAccount,
ClusterRole and ClusterRoleBinding. It establishes that the CA observation
path works against a correctly scoped observer. It does **not** establish the
campaign observer's actual scoping; that check is
`establish_gcp_ca_observer` running the `expect_denied` sample against the
campaign kubeconfig at campaign time. Both checks are needed and answer
different questions.

## Environment

- kind v0.27.0 cluster `sol-observer-exercise` on Docker; deleted after the run.
- Alpha.43 install/candidate/workspace, target
  `qual-a43-gcp-3/gcp/us-central1`; the bound specimen's four consumers:
  `comms/fulfilment_worker`, `demo_ts/fulfillment_worker`,
  `demo_ts/order_svc`, `payments/orders_svc`.
- Synthetic workload generated from the specimen: one zero-replica Deployment
  per consumer with the declared `db-ca` ConfigMap volume and mount, the
  declared CA ConfigMap (throwaway self-signed CA), the dummy credential
  Secret, and no database, migration Job or Kafka.
- Scoped observer SA `sol-qualifier-observe` (kube-system): `get` namespaces,
  `get`/`list` Deployments, ConfigMaps and Jobs; no Secrets, exec, logs, patch
  or delete.
- Under-scoped observer SA `sol-qualifier-observe-narrow`: namespace `get` plus
  a namespaced Role only in `pluto-payments`, so reads elsewhere are denied.

## Results

**Positive.** `ca-application.json` `ok:true`; exit 0. Four PASS verdicts,
one per declared consumer:

```
PASS gcp/database-ca/database/ca/comms/fulfilment_worker       established
PASS gcp/database-ca/database/ca/demo_ts/fulfillment_worker    established
PASS gcp/database-ca/database/ca/demo_ts/order_svc             established
PASS gcp/database-ca/database/ca/payments/orders_svc           established
```

Capture: `{"digest":"36792ad2ac0977dff8d9550c71248853841b3b665ffc17511673e8a5981ee4d4","size":2121,"kind":"observation"}`.
The capture is a pointer list; the verdicts above are the consumers it names.

**Denied read.** With the under-scoped observer, `ca-application.json` is
`ok:false`, exit 1, and the report names the specific read:

```
could not establish read authority for configmaps in pluto-comms
(exited with code 1: no); the CA family is unestablished
```

**CA mismatch.** With one Deployment's `db-ca` volume pointed at another
ConfigMap, `ca-application.json` is `ok:false`, exit 1; the verdict is FAIL on
`gcp/database-ca/database/ca/comms/fulfilment_worker` with detail
`CA mount references another volume source`. The other three consumers pass,
which also shows the failure is scoped to the mutated consumer.

**Authorization sample.** The scoped observer was denied all eight sampled
verbs in all four required namespaces: 32 `auth can-i` results, every one
`no` (Secrets get/list, pods/exec create, pods/log get, Deployments/ConfigMaps/
Jobs patch, Jobs delete). No unexpected grant.

**Cleanup.** `kind delete cluster` succeeded; `kind get clusters` is empty; the
observer, narrow-observer and admin kubeconfigs were removed. No cloud
resource was created.

Evidence (host, outside the repository): `/home/logan/qual-observer/evidence/`
contains `positive-report.json`, `positive-capture.json`, `denied-report.json`,
`mismatch-report.json`, `auth-can-i.txt`, `auth-can-i-unexpected.txt` (empty),
`request-{positive,denied,mismatch}.json`, `summary.txt`,
`kind-clusters-after.txt`, and the three `ca-evidence/` stores. The evidence
directories are private (0700); the CA evidence store refused them otherwise.

## Finding: read-authority refusal had no report

The first exercise exposed that `check_read_authority` ran before the evidence
store opened. A denied read exited 1 with no report, so the denied case could
not distinguish a refusal from a crash. This PR makes the refusal path write
`{"phase":...,"ok":false,"errors":[...]}` before exiting; the denied report
above is the result. Without that fix the required `ok:false` evidence for the
denied case does not exist.

## Non-claims

- No GCP provider, IAM or Workload Identity path; this is local Kubernetes RBAC.
- No campaign-observer scoping claim; see `establish_gcp_ca_observer`.
- No migration CA phase and no family report; application phase only.
- No DML, Kafka, TLS or release verdict.

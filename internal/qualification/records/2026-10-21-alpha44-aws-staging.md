# AWS staging qualification — alpha.44 attempt a44-aws-2 — 2026-10-21

Status: **FAILED at app; staging mechanism-only; not promotion-eligible; no promotion.**
The staging certificate issued and the cloud passed; the app failed at the Kafka
delivery observation. That is the failure surface this attempt was meant to expose.

## Candidate and harness

- `v0.1.0-alpha.44`, revision `8c74717712696f682d46571d3284138c015fa43e`.
- Harness #1619 merged: AWS defaults to staging; attempt identity records
  `issuer=letsencrypt-staging`, `claim=mechanism-only`, `promotion_eligible=no`.
  A continuation preserves the original labels (the `continued` entries).
- Target `qual-a44-aws/aws/us-east-1`, cluster `sol-qual-aws-a44`.

## Phases

| Phase | Exit | Note |
|---|---|---|
| prepare | 0 | candidate-bound images built |
| cloud | 0 | staging certificate; platform reconciled; artifact gate; images published; plan |
| app | 1 | Kafka delivery observation: `kubectl deployments failed` |
| destroy | 0 | independent inventory ABSENT |
| verify | 0 | absence re-read; `promotion_eligible=no` |

The staging cloud passing confirms the LE cadence fix: a staging attempt reaches
the same platform/cloud state at zero production budget.

## App failure

```text
[02:15:39] app-transaction
Kafka delivery observation failed: kubectl deployments failed (exit 1); output withheld
```

The app reached the migration gate, established the observation transport,
deployed, delivered the database and CA to every consumer, and began the
transaction. The Kafka delivery observation then failed reading Deployments.
This is a real observation-path failure (the qualifier/transport boundary), not
a staging-certificate failure; the output is withheld by the observer, so the
next step is to expose the specific `kubectl` error and fix the observation
boundary (#1601/#1597 class). No rerun was attempted.

## Teardown

`destroy=0`; independent inventory ABSENT for every required disposable class;
`verify=0` re-read ABSENT. `promotion_eligible=no`; `required_phases_ok=no`.

The verify reports `attempt_continuity=resumed` and `resumed_from=` (empty).
That is a small verify defect: this attempt is continuous and has no resume.
The empty field is being treated as a resume. Recording it here rather than
fixing the verify in the same change; the promotion verdict is unaffected (the
attempt is ineligible either way).

## Non-claims

- No clean pass and no promotion. The app transaction and Kafka delivery are
  not claimed; the app stopped at the Kafka observation.
- No production-certificate claim; this attempt is mechanism-only by construction.
- No GCP claim.

## Next

1. Expose the specific `kubectl` error behind the Kafka observation and fix the
   qualifier/transport read boundary.
2. Re-run an AWS staging attempt; if it passes clean, run the production
   promotion attempt after the LE reset (`2026-10-21 13:47:59 UTC`).

# Database-CA regression coverage

The live AWS and GCP rows use the shared candidate-bound evaluator. The temporary
comparison against the former shell predicates is retired; Git retains that baseline.
This mapping identifies the meaningful cases and their continuing owners. It is a
coverage map, not a second policy catalog or a claim of runtime TLS verification.

Paths below are relative to `internal/tooling/sol_qualification/test/` unless stated.

| Historical cases | Retained regression owner |
|---|---|
| Healthy AWS/GCP CA delivery | `test_kubernetes.ml:test_shared`; compiled-driver happy AWS/GCP scenarios in `test_candidate_boundary.py` |
| One missing consumer CA; CA only in migration namespace | `test_live_kubernetes.ml`: "declared consumer missing CA fails"; `test_kubernetes.ml:test_failures` checks positively empty ConfigMap lists |
| One missing consumer Deployment, wrong volume source, or absent volume among healthy neighbours | `test_kubernetes.ml:test_single_consumer_failure` (transferred focused cases) |
| Forbidden, timeout, spawn failure, malformed/empty successful output | `test_kubernetes.ml:test_failures`; authenticated process "malformed output" and auth-failure tests |
| Empty exercise / missing CA declaration | `test_domain.ml:test_decoding`; candidate projection refusal cases in `test_candidate_boundary.py` and `cli/test/test_database_contract_binding.py` |
| Wrong/empty CA key; wrong ConfigMap name/namespace | `test_kubernetes.ml:test_projection` |
| Wrong Deployment identity/namespace/schema | `test_kubernetes.ml:test_schema`; `test_live_kubernetes.ml:test_query_mismatch` |
| Redirected mount, sidecar-only mount, unmounted volume, shadowed CA file | `test_kubernetes.ml:test_mounts` |
| Omitted/redirected projected key | `test_kubernetes.ml:test_mounts` (items omitted/renamed) |
| Wrong observation identity / endpoint / freshness | `test_kubernetes.ml:test_context`; authenticated process identity/cluster/configuration rotation cases |
| Healthy application delivery cannot cover missing migration CA | `test_migration_ca.ml:test_application_success_cannot_cover_migration`; "migration ConfigMap absent" |
| Valid consistently renamed volume | `test_candidate_boundary.py:test_boundary_integrated_path_renamed_volume_passes` |
| Nonconsumer has no CA obligation | `test_domain.ml:test_golden`; authenticated process "nonconsumer excluded; complete consumers pass"; compiled-driver scenarios |
| Missing DDL/DML Secret is outside the CA predicate | Provider `app_verify_database_delivery` tests in `internal/qualification/aws/stubbed-qual-test.sh` and `internal/qualification/gcp/stubbed-qual-test.sh` |
| Migration Job substitution, missing execution, incomplete discovery | `test_migration_ca.ml` and `test_live_kubernetes.ml` migration cases |

The comparison-only checks for extracting historical functions, unsupported fixture
queries and differences in the former predicates are intentionally removed. They do
not protect the current implementation. Old ConfigMap command failures were UNKNOWN;
a successful complete empty list is FAIL for required presence. Both refuse success,
and the retained tests distinguish absence from an unreadable observation.

The current checks establish structural CA delivery, candidate/subject binding and
coverage. They do not establish running-Pod file contents, intended certificate bytes,
actual database privileges, or runtime enforcement of TLS verification.

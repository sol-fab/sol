# External-resource qualification fixtures

The phase directories are **inputs**, not a parallel qualification framework.
They provide the application image and target bindings for an external queue or
object store. A live qualification must wrap them with the shared harness:

- `attempt.sh` for one attempt identity and evidence directory;
- `sol-under-test.sh` for the released artifact under test;
- `record.sh` and the qualification contract for the evidence record;
- the provider's independent absence inventory for cleanup.

A fixture run without those wrappers is mechanism evidence only and must not be
recorded as production qualification.

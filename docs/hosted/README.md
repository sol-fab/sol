# Hosted Sol

This directory is intentionally almost empty. It exists so that a reader who finds
"hosted" in the repository gets the boundary answer rather than a stale design.

## Hosted is a separate product

The hosted platform — the control plane, builder and runner, dashboard, metering
and billing — is its own application in its own repository (`DEC-019`). This
repository is the open-source tool plus the interface a hosted service may consume,
and the dependency is one-way: **nothing here may depend on, require, or reference
anything private.** A public Apache-2.0 product that needs private code is not open
source in any meaningful sense.

A hosted offering is optional, not a prerequisite for the core product. The
developer experience this repository promises is delivered entirely from the CLI,
the user's CI, and resources installed into the user's own cloud account —
[`docs/developer-experience.md`](../developer-experience.md), and `DEC-057` §5 for
the boundary test a hosted component must pass.

## What used to be here

Three design documents lived in this directory: a hosted account/environment model,
a default-URL and custom-domain flow, and a hosted release-inspection model. All
three described a hosted control plane (`sol cloud deploy`, Sol-managed default
URLs, a hosted executor) that was spiked in Phase 7 and **removed on 2026-06-22**,
before the self-hosted factory contract hardened. They were left behind describing
a product that no longer existed, which is worse than having no page: a reader
would take them for current fact.

They were removed on 2026-09-29. Their content remains in git history if it is ever
wanted as a design input, and the product-level direction that replaced them is in
[`docs/developer-experience.md`](../developer-experience.md).

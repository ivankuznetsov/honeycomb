# Package and Catalog Contract

`docs/PACKAGE_FORMAT.md` is the public authority. This page records the compact
cross-task contract for agents implementing CI, seeding, site, or installers.

## Package identity

- Releases live at immutable `packages/<name>/<semver>/` paths.
- `honeycomb-manifest/v1` is strict and independent from Hive/hive-bench schemas.
- Authors own metadata and safe top-level `x-*`; generation owns normalized
  permissions, exact payload file SHA-256s, and `release_sha256`.
- Only root `manifest.yml` is excluded from payload hashing. An evolving review
  file placed inside a version would be immutable hashed package content.
- `source.revision` is upstream provenance, not registry release or reviewed-head
  identity.

## Consumer catalog

`honeycomb-catalog/v1` is a flat name-then-SemVer list. Each eligible version
contains its own version plus the highest eligible `latest_version`. The future
install string always selects `honeycomb/<name>`; exact-version Hive resolution
is outside this repository.

The catalog projects manifest description/author/license/Hive minimum/permission
data, evidence tier/review metadata, deterministic package and review URLs,
source SHA, and a compact listing-approval identity. It does not embed full
manifests or timestamps generated at runtime.

Catalog generation validates all packages before filtering. Therefore a broken
unlisted package aborts output rather than hiding behind missing evidence.

## Handoffs

- Task 1849: produce/adapt normalized evidence and invoke validator/catalog
  checks in CI.
- Task 1850: define trust policy without mutating immutable package payloads or
  silently accreting v1 catalog fields.
- Task 1851: add real packages, generated manifests, evidence integration, and a
  populated catalog.
- Static site: consume catalog entries as generated; do not reinterpret package
  manifests independently.
- Hive tasks 1852/1853: consume the documented install command/latest semantics.

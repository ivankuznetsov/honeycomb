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

`honeycomb-catalog/v1` is a flat name-then-SemVer list. Every dual-gated version
remains present, including soft-hidden, yanked, and revoked releases. Each entry
contains its own version plus the highest dual-gated `listed` `latest_version`
or `null`. The future install string always selects `honeycomb/<name>`;
`HoneycombRegistry::Catalog.resolve` defines the catalog-side exact behavior.

The catalog projects manifest description/author/license/Hive minimum/permission
data, independent trust/lifecycle/review metadata, deterministic package and
review URLs, source SHA, and a compact listing-approval identity. It does not
embed full manifests or timestamps generated at runtime.

The contract carries immutable `release_tier`, mutable `current_tier`,
authoritative `permission_risk`, lifecycle `state`, Verified signature and
attestation evidence, ordered tier/state `history`, and public `advisories` as
independent fields. Discovery/latest use only `listed`. Exact resolution remains
allowed for `soft_hidden` and `yanked`; `revoked` raises with mandatory public
advisories. Historic Verified releases retain verification even after current
demotion to Community.

Low/moderate risk needs one current approved maintainer. High risk needs two
distinct current approvals for the same release and exact review head; any
current denial makes the version ineligible. Verified evidence binds the
canonical immutable archive identity to an exact GitHub Actions keyless signer
and attestation workflow identity.

Catalog generation validates all packages before filtering. Therefore a broken
unlisted package aborts output rather than hiding behind missing evidence.

## Handoffs

- Task 1849: produce/adapt normalized evidence and invoke validator/catalog
  checks in CI.
- Task 1850: publish reviewer/trust policy prose using the shipped independent
  tier/risk/state/verification/advisory fields.
- Task 1851: add real packages, generated manifests, evidence integration, and a
  populated catalog.
- Static site: consume catalog entries as generated; do not reinterpret package
  manifests independently.
- Hive tasks 1852/1853: consume the documented install command/latest semantics.

# Package and Catalog Contract

`docs/PACKAGE_FORMAT.md` is the public authority. This page records the compact
cross-task contract for agents implementing CI, seeding, site, or installers.

## Package identity

- Releases live at immutable `packages/<name>/<semver>/` paths.
- The exact-base security gate rejects any changed root already present at the
  base revision; fixes must add a wholly new SemVer directory.
- `honeycomb-manifest/v1` is strict and independent from Hive/hive-bench schemas.
- Authors own metadata and safe top-level `x-*`; generation owns normalized
  permissions, exact payload file SHA-256s, and `release_sha256`.
- Only root `manifest.yml` is excluded from payload hashing. Mutable community
  reviews live separately at `reviews/<name>/<version>/<github-user>.md` and
  never enter the package file map or archive identity.
- `source.revision` is upstream provenance, not registry release or reviewed-head
  identity.

## Consumer catalog

`honeycomb-catalog/v2` is a flat name-then-SemVer list. Every dual-gated version
remains present, including soft-hidden, yanked, and revoked releases. Each entry
contains its own version plus the highest dual-gated `listed` `latest_version`
or `null`. The future install string always selects `honeycomb/<name>`;
`HoneycombRegistry::Catalog.resolve` defines the catalog-side exact behavior.

The catalog projects manifest description/author/license/Hive minimum/permission
data, independent trust/lifecycle/review metadata, deterministic package and
review URLs, source SHA, and a compact listing-approval identity. It does not
embed full manifests or timestamps generated at runtime.

Catalog `reviews_url` preserves the exact designated-maintainer approval URL.
Nullable `community_reviews_url` is the default-branch external community-review
directory only when records exist. Every designated review also remains in
`listing_approval.reviews`; neither community content nor verdict counts affect
eligibility.

V2 adds nullable `community_reviews_url` without changing v1 `reviews_url`.
`schemas/catalog-v1.json` is retained unchanged as the strict historical
contract; current producers emit v2 and consumers branch on the root schema.

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
Offline approval export requires prior normalized evidence and preserves
unselected versions plus tier/state/verification/history/advisory projections,
so refreshing lint cannot silently relist or demote a version.

## Handoffs

- Task 1849: produce/adapt normalized evidence and invoke validator/catalog
  checks in CI.
- Task 1850: shipped the canonical public contribution, security, trust, and
  community-review policies plus their documentation contract tests.
- Task 1851: add real packages, generated manifests, evidence integration, and a
  populated catalog.
- Static site: consume catalog entries as generated; do not reinterpret package
  manifests independently.
- Hive tasks 1852/1853: consume the documented install command/latest semantics.

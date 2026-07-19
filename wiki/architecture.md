# Architecture

`honeycomb` is a reviewed registry for publishable Hive workflow packages called
honeycombs. The repository now contains an independent v1 package/manifest
contract, deterministic derived catalog, offline author/CI command library, and
fork-safe security-lint workflows. It still has no web application or static
catalog renderer.

## Current Repository Shape

- `lib/honeycomb_registry/` is the shared Ruby implementation for schemas,
  filesystem safety, manifest derivation, validation, Hive compatibility,
  evidence loading, and catalog projection.
- `script/honeycomb-{manifest,validate,catalog}` are thin public entrypoints.
- `lib/honeycomb_security_lint/` scans untrusted submitted bytes, renders
  redacted evidence, adapts approved results to the catalog reader, parses
  hostile artifacts, and performs trusted GitHub metadata reporting.
- `script/honeycomb-security-lint` is the unprivileged analyzer entrypoint;
  `script/honeycomb-security-lint-report` is default-branch reporter plumbing.
- `script/honeycomb-listing-approval` is trusted approval workflow plumbing and
  the offline exporter for checked-out evidence snapshots.
- `script/honeycomb-reviews` validates strict community-review records either
  from the current tree or from untrusted pull-request objects at an exact SHA.
- `.github/workflows/security-lint.yml` and `security-lint-report.yml` implement
  the read-only analyzer / metadata-write reporter split.
- `.github/workflows/listing-approval.yml` verifies a maintainer's current
  review and appends immutable lint/approval records to `honeycomb-evidence`.
- `.github/workflows/community-reviews.yml` runs trusted base code against
  submitted Git objects without checking out or executing pull-request code.
- `.github/workflows/catalog-check.yml` is a read-only publication gate that
  runs the complete source contract suite against an exact Hive source commit,
  then compares submitted `catalog.json` bytes with the protected normalized
  evidence branch.
- `packages/<name>/<semver>/` is the immutable release store. The historical
  `bench/0.1.0`, `docs-sync/0.1.0`, and production canary
  `task-inspect/0.1.0` are present, alongside canonical but not-yet-listed
  Architecture, Writing, and SEO Content 1.0.0 packages.
- `reviews/<name>/<version>/<github-user>.md` is the mutable, external
  community-review namespace; checked documentation fixtures demonstrate its
  strict record shape without creating production reviews.
- `catalog.json` is canonical generated output using Hive's compact,
  lexicographically keyed, NFC-normalized workflow-registry JSON bytes. Its
  first listed entry is the low-risk Community `task-inspect/0.1.0` canary
  selected by protected listing evidence; the strict v1 schema remains
  archived unchanged for explicit legacy consumers.
- `policy/spdx-license-ids.txt` is the offline license identifier snapshot.
- `test/fixtures/` and `test/run.rb` prove the format without a network or gem
  install. The production listing-evidence fixture mirrors the public protected
  record solely so the committed catalog can be re-derived offline in tests.
- `test/flagship_hive_execution_test.rb` builds a temporary immutable Git
  registry from the three real package trees, then exercises a compatible Hive's
  registry client, install/configuration store, managed task creation, pinned
  runtime context, optional-input isolation, package tools, and real Agent and
  Council engines with deterministic test agents. It does not claim an
  authenticated provider-backed run.
- `docs/PACKAGE_FORMAT.md` is the authoritative public format/command contract;
  root `CONTRIBUTING.md`/`SECURITY.md` and `docs/TRUST.md`/`REVIEWS.md` are the
  canonical public policy; `wiki/` records agent-facing architecture and
  cross-task boundaries.

## Intended Product Shape

The shared library has three main flows:

1. Manifest generation safe-loads author metadata and `workflow.yml`, verifies
   the package boundary, derives the worst-case permission union, hashes every
   regular payload file except the root manifest, fingerprints the canonical
   projection, and atomically replaces `manifest.yml`.
2. Validation performs the same structure/derivation/integrity checks without
   writes. It optionally loads Hive and calls its public descriptor parser;
   strict mode makes compatibility mandatory.
3. Catalog generation validates all packages first, strict-loads an explicit
   normalized evidence record set, omits versions without current gates, rejects
   stale or contradictory identities, retains dual-gated lifecycle history,
   computes `listed`-only SemVer latest values, and atomically replaces
   `catalog.json`.
4. Security lint discovers changed version roots from the exact base/head diff,
   rejects modification, rename, or deletion of a version directory already
   present at the base revision,
   invokes the production validator, scans all bounded text content, statically
   analyzes every UTF-8 instruction surface with item budgets, and emits
   canonical redacted evidence.
5. The default-branch reporter verifies the workflow run, current PR head,
   complete changed-file set, newest same-head source run, protected paths,
   artifact ZIP/digests/schema/identity, then updates the
   `honeycomb/security-lint` commit status and one best-effort owned comment.
6. The protected approval issuer re-verifies maintainer permission, review,
   status, artifact, release, and head identities before appending records on a
   separate evidence ref. It can finalize exact requested suppressions from
   preliminary failure to a proven pass. Offline export explicitly selects lint
   snapshots, requires prior normalized evidence, preserves durable lifecycle
   state and unselected records, projects the latest decision per reviewer, and
   adapts matching approvals to the catalog reader.
7. Community-review validation binds strict path/front matter and authenticated
   PR identity to canonical package, catalog, release, source, and review-head
   identities. It is informational and cannot mint listing approval.

`source.revision`, generated `release_sha256`, and review `head_sha` are separate
identities. Evidence binds both lint and human approval to the latter two.
The installer materializes package bytes from its verified catalog commit;
`head_sha` remains review evidence because squash merging need not preserve it
as a default-branch ancestor. Human package links use the default branch and
immutable version path.
Release/current trust tier, permission risk, lifecycle state, verification,
history, and advisories remain independent catalog axes. Revoked entries remain
auditable but exact resolution fails closed with their public advisories.
Catalog `reviews_url` retains the designated approval audit meaning;
`community_reviews_url` resolves to the mutable external namespace only when a
community record exists.

## Runtime Flow Status

Author tooling, seed packages, security-lint CI, and the read-only catalog drift
gate are shipped on this branch. Analyzer/exporter code is deterministic and
offline; only the trusted reporter and approval issuer use GitHub HTTPS metadata
APIs. Protected normalized evidence now projects the listed Community
`task-inspect/0.1.0` release into catalog commit
`bf67e8a6bc4a85e2d6663c57595d337e17ce9f73` with canonical SHA-256
`2e6c27ed6ec22bc3e6afc5ff07244418d48a6e878c53a3e850326748d8d5c497`.
The static site consumes that exact snapshot without reconstructing entries,
and released Hive v0.5.2 installs it from the official registry with immutable
catalog/digest task pins and task-local read-only runtime policy. Evidence
branch/environment protection remains live; emergency lifecycle transitions
and positive community-review identity cases remain rollout operations.

The flagship packages are ahead of that released runtime: their per-slot agent
mapping, configuration digest, exact actor policy, optional input, prompt-asset,
and package-root contracts require the compatible Hive prerequisite release.
Local cross-repository proof does not make those versions public. Protected
reviews, catalog projection, site publication, and live provider evidence
remain ordered gates.

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
- `.github/workflows/security-lint.yml` and `security-lint-report.yml` implement
  the read-only analyzer / metadata-write reporter split.
- `.github/workflows/listing-approval.yml` verifies a maintainer's current
  review and appends immutable lint/approval records to `honeycomb-evidence`.
- `packages/<name>/<semver>/` is the immutable release store; it is empty except
  for `.gitkeep` until seeding work lands.
- `catalog.json` is canonical generated output and currently contains the empty
  `honeycomb-catalog/v1` document.
- `policy/spdx-license-ids.txt` is the offline license identifier snapshot.
- `test/fixtures/` and `test/run.rb` prove the format without a network or gem
  install.
- `docs/PACKAGE_FORMAT.md` is the authoritative public format/command contract;
  `wiki/` records agent-facing architecture and cross-task boundaries.

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
   normalized evidence record set, omits non-approved versions, rejects stale or
   contradictory identities, computes eligible SemVer latest values, and
   atomically replaces `catalog.json`.
4. Security lint discovers changed version roots from the exact base/head diff,
   invokes the production validator, scans all bounded text content, statically
   analyzes only instruction surfaces, and emits canonical redacted evidence.
5. The default-branch reporter verifies the workflow run, current PR head,
   protected paths, artifact ZIP/digests/schema/identity, then updates one owned
   comment and the `honeycomb/security-lint` commit status.
6. The protected approval issuer re-verifies maintainer permission, review,
   status, artifact, release, and head identities before appending records on a
   separate evidence ref. Offline export explicitly selects current lint
   snapshots and adapts matching approvals to the catalog reader.

`source.revision`, generated `release_sha256`, and review `head_sha` are separate
identities. Evidence binds both lint and human approval to the latter two.

## Runtime Flow Status

Author tooling and security-lint CI are shipped. Analyzer code is deterministic
and offline; only the trusted reporter uses GitHub HTTPS metadata APIs. The
remaining consumer flow is future work: task 1851 seeds real honeycombs, a
static site exposes `hive.sh/honeycombs`, and Hive tasks 1852/1853 implement
`hive workflow install honeycomb/<name>`. Evidence branch/environment creation
and protection remain post-merge repository rollout operations.

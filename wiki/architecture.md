# Architecture

`honeycomb` is a reviewed registry for publishable Hive workflow packages called
honeycombs. The repository now contains an independent v1 package/manifest
contract, deterministic derived catalog, and offline author/CI command library.
It still has no web application, static catalog renderer, or listing workflow.

## Current Repository Shape

- `lib/honeycomb_registry/` is the shared Ruby implementation for schemas,
  filesystem safety, manifest derivation, validation, Hive compatibility,
  evidence loading, and catalog projection.
- `script/honeycomb-{manifest,validate,catalog}` are thin public entrypoints.
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

`source.revision`, generated `release_sha256`, and review `head_sha` are separate
identities. Evidence binds both lint and human approval to the latter two.

## Runtime Flow Status

Author and CI tooling is shipped and offline. The remaining consumer flow is
future work: task 1849 produces/adapts review evidence, task 1851 seeds real
honeycombs, a static site exposes `hive.sh/honeycombs`, and Hive tasks 1852/1853
implement `hive workflow install honeycomb/<name>`.

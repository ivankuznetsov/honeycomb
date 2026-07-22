## 2026-07-22 — Build the unversioned Async Fix candidate

- Added a manifest-free two-stage Async Fix source under `candidates/` with one
  configurable high-risk development mapping and a controller-owned draft-PR
  handoff.
- Added temporary-registry contract coverage that proves the medium effort
  recommendation without embedding agent, model, or effort identity and keeps
  the candidate outside package discovery and catalog generation.
- Added exact-Hive acceptance for install consent/provenance, agent remapping,
  direct and compact plan/debug fixes, no-fix and blocked outcomes, auth
  failure, push/create recovery, secret quarantine, and unchanged source
  checkouts.
- The acceptance pin is merged Hive PR #831 commit
  `57b52dca65c2b037f9bf09007cf523ff7859d855`, completing the U7 prerequisite
  checkpoint. U8 remains a separate container-proof unit. No package version,
  release, catalog entry, site publication, or deployment was created.
- Synchronized the catalog and security-lint checkouts plus all exact-runtime
  contract tests to that one merged Hive runtime so the complete registry
  suite exercises a single clean runtime identity.

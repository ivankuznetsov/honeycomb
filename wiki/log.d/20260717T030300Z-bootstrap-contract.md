# 2026-07-17: Bootstrap source, scope, and evidence contracts

- Defined the exact `../../../..` Hive task-to-project anchor so scoped
  manifests distinguish project paths from task paths and do not overstate
  every write tool as repository-wide access.
- Fixed normalized state at
  `honeycomb-evidence:normalized/listing-evidence-v1.json`.
- Defined a two-commit registry-original release flow that preserves a real
  source commit in default-branch ancestry without a self-referential identity.
- Recorded that qualified file rules require the first Hive release containing
  the portable path-rule contract; v0.4.2 is not a compatible minimum.

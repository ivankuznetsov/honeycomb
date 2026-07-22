# Mapping recommendation contract

- Extended the strict `x-hive` manifest contract with optional, sorted
  `mapping_recommendations` entries containing a stable executable `slot` and
  optional portable `low`, `medium`, or `high` effort.
- Kept recommendations non-binding and agent-agnostic: manifests cannot embed
  an agent or model, and manifests without recommendations retain existing
  behavior.
- Added registry shape validation, Hive-compatible executable-slot checks, and
  focused rejection coverage for malformed, duplicate, unsorted, terminal, and
  unknown recommendations.
- Advanced trusted CI to merged Hive commit
  `3f91a71bdb29fd641eca9c3dd38d2ddb7a1f1bb6` and added a shared full-package
  parity matrix that both Honeycomb and Hive validators must accept or reject
  identically.

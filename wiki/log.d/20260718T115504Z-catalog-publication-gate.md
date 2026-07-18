## 2026-07-18 — Catalog publication and durable package resolution

- Added a read-only GitHub Actions gate that runs the complete registry contract
  suite against an exact compatible Hive source commit, then checks committed
  `catalog.json` against the protected normalized evidence branch on pull
  requests, default-branch pushes, and explicit reruns.
- Separated transient designated-review head identity from installation:
  installers materialize immutable package paths from the verified catalog
  commit, while human package links use the default branch.
- Documented the reviewed Honeycomb-to-Hive-site snapshot handoff and the
  remaining Hive v2 consumer, required-check, and live-canary rollout gaps.
- Aligned public catalog and schema identifiers with the deployed
  `hivecli.sh` domain.

## 2026-07-18 — Add a production submission canary

- Added a maintainer-dispatched workflow that opens a fixed, bot-authored
  `task-inspect` package submission with two-commit registry provenance.
- Kept lint labeling, human review, protected approval issuance, evidence,
  catalog publication, site synchronization, and Hive installation outside the
  canary's authority so the smoke test exercises the real trust boundaries.
- Documented the temporary repository settings and restoration requirements
  needed to run the canary without weakening steady-state protection.

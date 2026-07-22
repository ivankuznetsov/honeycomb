## 2026-07-22 — Pin trusted validation to released Hive v0.6.7

- Advanced the read-only catalog publication gate and unprivileged security
  analyzer from the pre-release Hive 0.6.6 source commit to released v0.6.7
  commit `af22485f9b2bee27a7497dc138e5e58ab9725bde`.
- Kept the dependency immutable and credential-free while allowing new package
  manifests to declare v0.6.7 as their actual released compatibility floor.
- Rebound the synchronized exact-Hive execution, compatibility, and Docker
  contracts to the same released commit, so the complete suite exercises the
  runtime the hosted gates load.
- Updated workflow contract tests so future trusted-runtime changes remain
  explicit, reviewable dependency updates.

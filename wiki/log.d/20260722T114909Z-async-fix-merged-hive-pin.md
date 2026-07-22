## 2026-07-22 — Pin Async Fix to the merged Hive runtime

- Merged Hive PR #831 with repository-owner authorization and recorded its
  resulting commit as `57b52dca65c2b037f9bf09007cf523ff7859d855`.
- Replaced the provisional PR-head checkout in Honeycomb CI and every
  exact-runtime contract with that merged commit.
- Completed the Async Fix U7 prerequisite checkpoint. U8's throwaway Docker
  proof remains separate; no package release, catalog listing, site
  publication, or deployment was created.

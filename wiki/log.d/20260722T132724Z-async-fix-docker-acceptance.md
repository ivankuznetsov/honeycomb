## 2026-07-22 — Prove Async Fix in default-deny Docker

- Added a disposable Ruby 3.4.5 acceptance harness for the unversioned Async
  Fix candidate and exact clean Hive commit
  `57b52dca65c2b037f9bf09007cf523ff7859d855`.
- Disabled container networking and image pulls, mounted source and dependency
  inputs read-only from Git-tracked snapshots, pinned the Ruby image digest,
  scrubbed credentials, bounded execution and cleanup, validated the exact
  proof summary, and default-denied unexpected provider, GitHub, Git transport,
  release, registry, and deployment calls.
- Exercised real Hive installation, mapping configuration, task creation,
  daemon dispatch, worktree repair, exact task-branch push, draft-PR creation,
  terminal rerun idempotency, recoverable PR-create failure, and manual
  mutation-free PR adoption.
- Kept the candidate outside `packages/` and `catalog.json`; no version, release,
  listing, site publication, deployment, or Hive-template removal was created.

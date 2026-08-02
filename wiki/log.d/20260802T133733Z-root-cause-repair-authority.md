## 2026-08-02 — Separate Root Cause Repair target authority from shared refs

- Added a manifest-free Root Cause Repair candidate without modifying immutable
  package 1.0.0 or selecting a successor version.
- Replaced aggregate-ref authority with a task-local, digest-bound moving
  checkpoint that compares individual ref creations, updates, and deletions.
- Allowed normal Hive-state, non-current branch, and remote-tracking movement;
  kept target, per-worktree, tag, stash, and unknown drift fail-closed.
- Added bounded evidence, one measurement retry, authorized stage checkpoint
  advancement, and structured blocked semantics for repeated authority races.
- Added real linked-worktree and native Hive regressions proving Hive state
  commits plus concurrent branch creation reach diagnosis while target movement
  still blocks.
- Kept manifest generation, version choice, release, catalog, publication, and
  deployment outside this candidate change.

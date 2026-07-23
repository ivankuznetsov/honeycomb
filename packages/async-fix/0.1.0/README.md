# Async Fix 0.1.0

Async Fix is a one-agent asynchronous fast lane for a small-to-medium UI or
backend defect. The mapped development agent may fix directly or use a compact
plan and debugging loop inside the same turn. A successful run leaves focused,
tested commits in an isolated worktree; Hive validates them, pushes the exact
task branch, and opens or adopts a draft pull request for maintainer review.

## High-risk execution boundary

The `fix` stage uses Hive's unbounded `yolo` permission preset so it can inspect
and modify a real repository, run project commands and tests, and create normal
commits. This is high-risk execution. Repository content and command output are
untrusted, and the selected runner may be able to observe ambient host state.
Use it only under the repository owner's authority and with a reviewed Hive
configuration.

GitHub transport remains controller-owned. The agent must not run `gh`, push,
force-push, open or update a PR, merge, release, publish, or deploy. Hive uses
the operator's existing authentication only for its exact, reconcile-first
draft-PR handoff. The maintainer retains all review and post-PR authority.

## Workflow

1. `inbox` captures `brief.md`, including optional reproduction evidence and
   base-branch context supplied when the task is created.
2. `fix` maps one agent-agnostic `development` slot. It diagnoses, optionally
   plans or debugs, applies the smallest cause-supported patch, runs focused
   checks, creates ordinary commits, and writes `fix-report.md`.
3. Hive validates the report, branch ancestry, committed objects, clean state,
   and publication projection. It records exactly one honest outcome:
   `pr-opened`, `no-fix`, or `blocked`.

The package metadata used by local acceptance recommends medium reasoning
effort for `stages.fix`; installation mappings remain an explicit maintainer
choice and are not part of workflow identity.

## Local acceptance

`test/async_fix_package_test.rb` proves the source topology, authority
boundary, canonical manifest shape, and package/catalog separation.
`test/async_fix_hive_execution_test.rb` requires the exact clean Hive revision
for released Hive 0.6.7 and exercises real install, configuration, task
creation, managed worktree execution, report validation, and draft-PR recovery
with deterministic local agent and GitHub transports. It covers direct and
compact plan/debug paths, remapping, no-fix, blocked, auth failure, push/create
retry, and secret quarantine while preserving both source checkouts.

Run the exact-Hive gate with:

```sh
HONEYCOMB_HIVE_SOURCE=/path/to/exact-clean-hive \
  ruby -Itest test/async_fix_hive_execution_test.rb
```

## Package status

This `0.1.0` directory is immutable package source. Its canonical manifest
binds the behavior bytes to the preserved registry source commit and declares
released Hive 0.6.7 as the minimum compatible runtime. Package presence and
local acceptance do not authorize protected listing evidence, a catalog entry,
site publication, deployment, or removal of a workflow shipped by Hive.

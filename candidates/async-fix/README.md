# Async Fix candidate

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

## Candidate status

This directory is unversioned source, not a package release. It intentionally
contains no `manifest.yml`, version directory, listing evidence, catalog entry,
or deployment metadata. Tests may copy these bytes into a temporary `0.0.0`
registry fixture inside a sandbox. Passing candidate or Hive acceptance does
not authorize promotion into `packages/`, a release/version choice, catalog or
site publication, deployment, or removal of a workflow shipped by Hive.

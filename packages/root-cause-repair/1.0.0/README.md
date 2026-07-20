# Root Cause Repair 1.0.0

Root Cause Repair turns an owner-supplied defect brief into a reproduced
failure, evidence-backed diagnosis, minimal repair, independent causal review,
and `repair-certificate.md`. The target repair remains an uncommitted working
tree mutation for its owner to inspect and control.

## High-risk execution boundary

This workflow permits arbitrary local command execution and repository
mutation. Every executable slot uses the explicitly unbounded `yolo` permission
preset. Install and run it only under the sole repository owner authority, in a
worktree whose current changes and recovery needs the owner understands. The
workflow may execute project code, tests, build tools, and hooks; repository
content and their output are treated as untrusted.

The actors must keep target changes uncommitted and Git refs unchanged. They
must not reset, clean, stash, revert, commit, push, open or update a PR, merge,
tag, release, publish, or deploy. The workflow does not transfer release or
remote-system authority to an agent.

## Workflow

1. `reproduce` establishes the original symptom and captures repository state.
2. `diagnose` proves the causal chain without implementing a repair.
3. `repair` applies the smallest root-cause fix and focused regression coverage.
4. `verification` uses one `causal-verifier` and up to three review/revision
   rounds to challenge the causal claim.
5. `certificate` produces `repair-certificate.md` with exactly one terminal
   outcome: `verified`, `not-reproduced`, or `blocked`.

Intermediate artifacts use `Workflow-Status` rather than a terminal outcome.
After `not-reproduced` or `blocked`, downstream actors no-op and propagate the
terminal condition. Reviewer `Verdict` values control the council loop; they
are not package outcomes.

The declared `tools/repository-state.rb` executable captures a content-blind,
deterministic repository-state fingerprint. Actors use it from the nested
`.hive-state` Git root to prove the target roots, HEAD, refs, index, tracked
worktree, and untracked worktree observations described in
`assets/evidence-contract.md`. It double-captures that bounded local state,
rejects hidden index flags, and places a hard deadline on Git subprocesses. It
does not attest that a remote or history-changing action never occurred and was
later hidden by restoring the same local state.

## Publication status

This source package is unpublished. No manifest is present, and no catalog,
listing, release, or installation claim is made for version 1.0.0.

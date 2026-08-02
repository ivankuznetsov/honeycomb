# Root Cause Repair candidate

This unpublished candidate turns an owner-supplied defect brief into a
reproduced failure, evidence-backed diagnosis, minimal repair, independent
causal review, and `repair-certificate.md`. The target repair remains an
uncommitted working-tree mutation for its owner to inspect and control.

## Repository authority correction

The released 1.0.0 workflow treats one aggregate digest of every Git ref as
target authority. In a real linked `.hive-state` worktree, normal Hive state
commits therefore invalidate diagnosis even when the checked-out target did not
move.

This candidate separates full repository observation from the authority
verdict. A task-local, content-blind checkpoint pins target HEAD, symbolic
branch, index, tracked and untracked bytes, and relevant refs. Individual ref
deltas are classified: the current target and per-worktree refs block;
non-current branches and remote-tracking refs are recorded and continue; tags,
stash, and unknown namespaces fail closed as ambiguous. Each stage compares
before acting and advances the checkpoint only after inventorying its authorized
worktree effects.

## High-risk execution boundary

This workflow permits arbitrary local command execution and repository
mutation. Every executable slot uses the explicitly unbounded `yolo` permission
preset. Install and run it only under the sole repository owner authority, in a
worktree whose current changes and recovery needs the owner understands. The
workflow may execute project code, tests, build tools, and hooks; repository
content and their output are treated as untrusted.

Actors keep target changes uncommitted. They must not reset, clean, stash,
revert, commit, push, open or update a PR, merge, tag, release, publish, or
deploy. The workflow does not transfer release or remote-system authority to an
agent.

## Workflow

1. `reproduce` establishes the symptom and creates the first authority
   checkpoint.
2. `diagnose` proves the causal chain without editing implementation or tests.
3. `repair` applies the smallest root-cause fix and focused regression coverage.
4. `verification` uses one `causal-verifier` and up to three review/revision
   rounds to challenge the causal claim.
5. `certificate` performs a final comparison and produces exactly one outcome:
   `verified`, `not-reproduced`, or `blocked`.

Intermediate artifacts use `Workflow-Status`. A `not-reproduced` or `blocked`
artifact makes downstream stages no-op and propagate that condition. Reviewer
`Verdict` values control the council loop; they are not package outcomes.

## Publication status

This is an unpublished candidate with no manifest. It is outside the canonical
`packages/<name>/<version>` tree and ignored by catalog generation and
package-wide validation. This candidate, its tests, and its pull request do not
authorize a version choice, package release, catalog listing, publication, or
deployment. Promotion remains a separate owner-authorized flow.

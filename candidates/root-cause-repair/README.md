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
non-current branches, remote-tracking refs, and managed LLM Wiki source-snapshot
refs are recorded and continue; tags, stash, and unknown namespaces fail closed
as ambiguous. Each stage compares
before acting, captures an exact content-blind digest after inventorying its
worktree effects, and advances only if a fresh capture still matches that
accepted delta. Checkpoints also bind a sequence and previous digest so the
certificate can verify the continuing stage chain.

## High-risk execution boundary

This workflow permits arbitrary local command execution and repository
mutation. Every executable slot uses the explicitly unbounded `yolo` permission
preset. Install and run it only under the sole repository owner authority, in a
worktree whose current changes and recovery needs the owner understands. The
workflow may execute project code, tests, build tools, and hooks; repository
content and their output are treated as untrusted.

Agents with `yolo` target-write authority are part of this workflow's trusted
computing base. Checkpoint self-digests detect accidental corruption, stale
stage evidence, and uncoordinated writes; they cannot authenticate state against
a hostile same-user process that can rewrite both the sidecar and stage
artifacts. That stronger custody boundary belongs in privileged Hive runtime
infrastructure, not in a self-signed workflow file.

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

Repair and verification have explicit one-hour bounds because they include the
implementation, focused regression, adjacent checks, and independent evidence
review. If a failed mutating attempt stops before it advances its checkpoint,
its partial bytes remain unattributed and the next attempt blocks safely; the
owner must reconcile them or begin from a fresh baseline rather than letting a
retry silently adopt them.

The terminal descriptor declares `verified` and `not-reproduced` as completing
outcomes and `blocked` as a blocking outcome. A compatible Hive runtime
validates the certificate's exact first line before its completion commit, so
`Outcome: blocked` remains an active, visibly blocked, explicitly retryable
task instead of being archived as successful completion.

The candidate execution regression runs separately against Hive commit
`ca0c429c0f7cbf3c912f2ffdd01b04a7890374b0`. Released package compatibility
tests continue to run against their immutable Hive 0.6.7 pin.

Intermediate artifacts use `Workflow-Status`. A `not-reproduced` or `blocked`
artifact makes downstream stages no-op and propagate that condition. Reviewer
`Verdict` values control the council loop; they are not package outcomes.

## Publication status

This is an unpublished candidate with no manifest. It is outside the canonical
`packages/<name>/<version>` tree and ignored by catalog generation and
package-wide validation. This candidate, its tests, and its pull request do not
authorize a version choice, package release, catalog listing, publication, or
deployment. Promotion remains a separate owner-authorized flow.

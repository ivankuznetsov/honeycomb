# Root Cause Repair

## Released contract

`packages/root-cause-repair/1.0.0` is immutable and publicly listed. It captures
content-blind Git state, reproduces a symptom, diagnoses a cause, leaves a
minimal repair uncommitted, runs causal review and revision, and emits
`verified`, `not-reproduced`, or `blocked`. Package presence, execution evidence,
and those semantic outcomes are distinct from release and publication
authority.

The 1.0.0 repository-state tool treats the digest of every ref below `refs/` as
one authority signal. Hive commonly implements `.hive-state` as a linked
worktree sharing the target's Git database. Normal workflow bookkeeping then
moves the non-target `hive/state` branch between stages. The target HEAD, index,
and files can remain identical while the aggregate ref digest changes, causing
diagnosis to block.

## Unpublished correction

`candidates/root-cause-repair/` is a manifest-free correction. It does not edit
the immutable release or select a successor package version.

The candidate writes `repository-authority.json` in the current task folder.
The sidecar moves with the task and is excluded from target byte authority. It
stores full content-blind ref records, target/root identities, HEAD, index, and
tracked/untracked digests. Checkpoint v2 also stores a monotonic sequence and
previous digest. Stage artifacts bind only its schema, sequence, and digest plus
bounded comparison evidence.

Ref changes are compared by the union of checkpoint and current names, so
creation, update, and deletion are equivalent drift events:

- the pinned symbolic branch and per-worktree namespaces are relevant;
- other local branches, remote-tracking refs, and managed
  `refs/llm-wiki/sources/` snapshot refs are unrelated to the pinned checked-out
  target;
- tags, stash, and unknown namespaces are ambiguous.

Relevant and ambiguous changes block. Unrelated changes continue and are
recorded. Evidence classification covers every delta before output is capped at
50 records per class, with exact count, digest, and truncation flag.

Reproduce creates the first checkpoint. Diagnose, repair, revision, and
verification compare before acting and atomically advance only after they
inventory worktree effects, obtain the exact content-blind delta digest, and
accept that digest for one fresh advancement capture. A late or extra mutation,
HEAD, index, relevant-ref, or ambiguous-ref drift cannot be authorized by
advancement. Certificate performs a terminal comparison after any decisive
command and checks the checkpoint chain without advancing. Measurement races retry
once; repeated authority movement blocks, while unrelated ref movement is
recorded without consuming the retry.

Repair and verification use explicit two-hour stage bounds after a live repair
reached the former implicit 30-minute default during its final evidence review.
The longer bound does not authorize recovery of partial target bytes. If a
failed attempt stops before checkpoint advancement, the next attempt cannot
distinguish its edits from concurrent owner work and blocks until the owner
reconciles the worktree or starts from a fresh baseline.

The candidate certificate also opts into Hive's semantic terminal contract:
`verified` and `not-reproduced` complete the task, while `blocked` becomes a
durable active error. Compatible Hive runtimes validate the exact first line
before committing completion, present the task as `Blocked`, retain guarded
explicit retry, and do not archive or automatically retry it. The immutable
1.0.0 package remains unchanged and does not carry this descriptor field.
The candidate-only execution gate runs in a separate Ruby process against Hive
commit `83ac363cb761a41345798ca05ad5f704c60b9795`; released-package gates retain
their existing immutable runtime pin.

## Evidence and boundary

Focused tests cover checkpoint integrity, bounded evidence, ref creation and
deletion, authorized repair advancement, out-of-band drift, and measurement
races. A temporary registry test installs the candidate into exact pinned Hive
bytes, uses a real linked `.hive-state` worktree, commits normal Hive state,
creates another task branch, and proves diagnosis continues. It also proves a
target branch move remains blocked.

This evidence boundary assumes workflow agents with target-write authority obey
their governing instructions. A self-digest can detect corruption and stale
evidence but is not a MAC against a hostile same-user actor that can rewrite
both the sidecar and Markdown evidence. Privilege-separated custody remains a
Hive runtime concern.

The temporary manifest and catalog exist only in the test sandbox. Candidate
source, tests, or a pull request do not authorize a package version, canonical
manifest, protected listing evidence, catalog projection, site publication,
deployment, or Hive template removal.

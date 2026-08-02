# Repository Authority Evidence Contract

`tools/repository-state.rb` emits one canonical JSON line and uses schema
`honeycomb-repository-state/v2`. Run it from the current Hive task folder. It
supports three operations:

- `create` captures the first phase-scoped checkpoint in the task-local
  `repository-authority.json` sidecar;
- `compare --expect <digest>` validates that sidecar against the checkpoint
  digest bound into the preceding stage artifact, then compares current state;
- `advance --allow-worktree --expect <digest>` performs the same comparison and
  atomically replaces the checkpoint only when the only target changes are the
  stage's inventoried tracked or untracked worktree effects.

The sidecar moves with the task folder between stages. It contains no target
file bytes, secrets, environment values, or timestamps. It stores content-blind
individual ref records so comparison does not have to put an unbounded ref list
in a prompt. Missing, corrupt, root-mismatched, or digest-mismatched sidecars
fail closed. Checkpoint writes use a mode-0600 temporary file, file and directory
sync, and atomic rename. Only this excluded Hive-state sidecar is written; the
tool never changes target bytes, the index, `HEAD`, or a Git ref.

## Target authority

Every checkpoint binds:

- the verified target and nested `.hive-state` root identities;
- symbolic `HEAD` and the resolved `HEAD` commit;
- every supported stage-zero index entry, including Git mode and object ID;
- tracked working-tree presence, mode, regular-file bytes, and symlink target;
- every non-ignored untracked regular file or symlink with the same treatment;
- every ref name, object ID, and object type below `refs/`.

`.git`, `.hive-state`, and Git-ignored entries are excluded from worktree byte
capture. This keeps Hive task files outside target authority even when
`.hive-state` is a linked worktree sharing the target Git database. The index
capture rejects `assume-unchanged`, `skip-worktree`, fsmonitor-valid, and
unmerged entries rather than normalizing hidden state.

Ref comparison operates over the union of old and current names, so creations,
updates, and deletions all count as changes. Classification is deterministic:

- the pinned symbolic branch and `refs/bisect/`, `refs/worktree/`, and
  `refs/rewritten/` are relevant;
- any non-current local branch and every remote-tracking ref are unrelated to
  the pinned checked-out target;
- tags, stash, and every other namespace are ambiguous.

Relevant and ambiguous changes block. Only unrelated changes continue. The
aggregate ref and snapshot fingerprints remain identities for complete
observations; they are not the authority verdict.

## Output and failure semantics

Successful output has `verdict: continue|blocked`. Its `reason` is one of
`unchanged`, `unrelated_refs`, `target_changed`, `ambiguous_refs`,
`checkpoint_created`, `checkpoint_existing`, or `checkpoint_advanced`.
Comparison classifies every changed ref before bounding evidence. Each
classification reports its exact count, digest, truncation flag, and at most 50
changed-ref records ordered by name.

The complete tracked and untracked capture repeats and must match. Target
authority plus relevant and ambiguous refs are rechecked around both passes.
Only unrelated ref movement during measurement is recorded and allowed to
continue. A `state_changed` measurement failure retries the complete capture
once; another authority movement returns structured error status and the
workflow maps it to `blocked`. The retry never normalizes semantic drift found
between stages.

The tool also fails closed for invalid invocation, unavailable Git authority,
unreadable or unsupported entries, files over 16 MiB, repositories over the
aggregate entry or byte limits, Git commands exceeding 60 seconds, and dirty,
uninitialized, commit-mismatched, or recursively dirty submodules. It disables
Git optional locking, does not refresh the index, does not follow worktree
symlinks, and invokes no network client.

This is current local-state evidence, not an operation ledger. It cannot prove
that a commit, push, or other remote action did not occur and was later hidden
by restoring the observed local state. Remote-action and history attestation
remain outside the contract and require separate owner-controlled evidence.

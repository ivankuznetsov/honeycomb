# Repository State Evidence Contract

`tools/repository-state.rb` emits one canonical JSON line. Successful output uses
schema `honeycomb-repository-state/v1` and binds its aggregate `fingerprint` to:

- the verified target and nested `.hive-state` root identities;
- symbolic `HEAD`, the resolved `HEAD` commit, and every ref below `refs/`,
  including `refs/stash`;
- every supported stage-zero index entry, including its Git mode, object ID,
  and the absence of `assume-unchanged`, `skip-worktree`, or fsmonitor-valid
  flags;
- tracked working-tree presence, mode, regular-file bytes, and symlink target;
- every non-ignored untracked regular file or symlink, with the same byte and
  mode treatment.

Paths and byte values are length-prefixed before hashing. The JSON exposes only
digests and counts for repository entries; it never emits file contents,
symlink targets, environment values, or timestamps. `.git`, `.hive-state`, and
Git-ignored entries are excluded from entry capture. Capture time belongs in
the enclosing workflow artifact and is never an input to this tool.

The command must run from within the Git-backed nested `.hive-state`. It derives
the target from that root's parent and verifies the parent is itself the target
Git root. It fails with canonical structured JSON and a nonzero exit status for
non-Git or incorrectly rooted invocation, unavailable Git authority, unreadable
or unsupported entries, unmerged index entries, files over 16 MiB, repositories
over the aggregate entry or byte limits, files that grow while read, Git
commands exceeding 60 seconds, concurrent state changes, and dirty,
uninitialized, commit-mismatched, or recursively dirty submodules. Ignored
paths are enumerated once, before the bounded directory walk.

The complete tracked and untracked capture is repeated and must match, with
HEAD, refs, and index authority checked around both passes. The tool is
read-only. Git optional locking is disabled; content capture disables filesystem
monitor shortcuts, while the separate index-flag check respects repository
configuration so hidden fsmonitor state cannot be normalized away. The
implementation does not refresh the index, write objects or refs, change
`HEAD`, follow worktree symlinks, read secrets, invoke a network client, or
modify target bytes. Identical target state at the same verified roots produces
byte-identical output in both independently packaged copies.

This is current local-state evidence, not an operation ledger. It cannot prove
that a commit, push, or other remote action did not occur and was later hidden
by restoring the observed local state. Remote-action and history attestation
remain outside the contract and require separate owner-controlled evidence.

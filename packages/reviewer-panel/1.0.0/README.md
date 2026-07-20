# Reviewer Panel

Reviewer Panel is an immutable Honeycomb package for reviewing and repairing
one exact Git working state. It establishes a complete state-bound basis, runs
four fixed semantic lenses in order—correctness, security, reliability, and
test-evidence—applies bounded repairs, re-runs every lens after a changed state,
and produces `merge-readiness.md` as analytical evidence.

The package is agent-agnostic. Hive asks during installation which compatible
execution profile should fill the basis, council, four reviewer, repair, and
readiness slots. Mapping several roles to the same execution profile or one
agent is valid, but it does not create multiple humans, independent providers,
or approval identities. The package embeds no agent, model, or effort choice.

Hive 0.6.0 operators using non-interactive `--yes` installation must explicitly
map every Reviewer Panel slot to a profile that can enforce that slot's policy.
The standard mixed Codex/Claude init configuration can otherwise suggest Codex
for one of the bounded read-only reviewer slots, which Hive correctly rejects
because that runner cannot enforce the requested tool scope. Interactive
installation remains the preferred path because it asks for every mapping and
shows suggested defaults; for automation, pass compatible per-slot `--mapping`
overrides (for example, map every slot to a configured Claude profile). Do not
weaken the workflow permissions to make an incompatible suggestion pass.

## Consequences and authority

This is a high-risk workflow. Basis capture, the test-evidence lens, repair, and
terminal verification can run arbitrary local command paths under `yolo`
admission. Accepted repairs mutate the target worktree and remain uncommitted.
That mutation is intentional and must be inspected by the owner.
Correctness, security, and reliability use bounded repository/task reads and
may write only their assigned review output; the council itself is read-only.
The default path needs no network or secret access, but operators must inspect
the installed permission projection and avoid concurrent repository writers.

The workflow never resets, cleans, stashes, reverts, commits, pushes, opens or
merges a PR, tags, releases, publishes, or deploys. `ready` is not human approval
or merge approval. It is state-bound analytical evidence for the sole owner,
and the owner retains sole authority over repository, registry, trust, release,
publication, and deployment decisions.

## Outcomes

- `ready`: four final lens results bind to one terminal state, required checks
  pass, no blocker remains, refs are unchanged, and workflow repairs remain an
  attributed uncommitted delta.
- `changes-requested`: a blocker remains at the repair cap, is outside allowed
  scope, is deferred, or was rejected without sufficient refuting evidence.
- `inconclusive`: intent, comparison base, repository evidence, or required
  verification is insufficient.
- `state-stale`: an external or test-created repository change invalidated the
  panel's evidence.

The state checkpoint detects drift but is not an atomic worktree lock. V1 is
Git-only and fails closed for unsupported repository states such as dirty or
uninitialized submodules and special entries. Command excerpts are bounded and
secret-like evidence must be redacted. State is captured twice, hidden index
flags are rejected, and Git subprocesses have a hard deadline. The resulting
fingerprint is current local-state evidence, not proof that no remote or
history-changing action occurred and was later hidden by restoring local state.

This `1.0.0` directory is an immutable package source. Its canonical manifest
binds the behavior bytes to the preserved registry source commit. Package
presence and local verification alone are not catalog-listing,
installation-from-catalog, publication, or deployment proof; protected listing
evidence and the generated catalog remain the authority for those states.

# Docs Sync honeycomb

Turn a bounded set of source changes into a focused documentation update. The
`inspect` stage records relevant source paths, `docs/**` targets, and a concise
rationale; `update-docs` consumes that handoff and changes only project
documentation below `docs/**`.

## Install

Requires Hive 0.6.0 or newer for install-time agent mappings:

```sh
hive workflow install honeycomb/docs-sync
```

## Permissions

This workflow uses normal agent tools. Its requested changes remain the two
task state files plus repository `docs/**`; that scope is a task instruction,
not a sandbox. The generated manifest discloses high-risk trusted execution.

## Flow

1. Place the changed source/documentation set in the task workspace.
2. `inspect` creates a three-field handoff in `inspect.md` without editing
   documentation.
3. `update-docs` edits only `docs/**`, lists every changed file, and completes
   as an explicit no-op when no update is needed.

## Trusted execution

This owner-trusted workflow explicitly uses `permissions: yolo` for every
agent, council, reviewer, and reviser. Agents use their normal tools and write
task artifacts directly; Hive adds no workflow sandbox or tool allowlist.
This is high-risk execution with the invoking user's normal access. Install
only workflows you trust. Task scope, evidence requirements, owner approvals,
and publication checks still apply; trust does not authorize unrelated changes.

# Docs Sync honeycomb

Turn a bounded set of source changes into a focused documentation update. The
`inspect` stage records relevant source paths, `docs/**` targets, and a concise
rationale; `update-docs` consumes that handoff and changes only project
documentation below `docs/**`.

## Install

Requires Hive 0.4.3 or newer (the first release expected to contain portable
qualified file rules):

```sh
hive workflow install honeycomb/docs-sync
```

## Permissions

This Community tutorial requests repository/task read access and writes only
its two task state files plus repository `docs/**`. It has no broad task or
repository write grant, shell, network, or secret access. The generated
`manifest.yml` is the authoritative permission projection.

## Flow

1. Place the changed source/documentation set in the task workspace.
2. `inspect` creates a three-field handoff in `inspect.md` without editing
   documentation.
3. `update-docs` edits only `docs/**`, lists every changed file, and completes
   as an explicit no-op when no update is needed.

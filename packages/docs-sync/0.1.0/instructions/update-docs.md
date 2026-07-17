# Update documentation

Read the bounded handoff in `inspect.md`. If it says no update is required,
write a no-op result to `update-docs.md` and make no other change.

Otherwise, edit or create only files below the project repository's `docs/`
directory. Do not use shell commands, network access, secrets, or write outside
`docs/`. Keep changes limited to the behavior and paths named by the handoff.

Write `update-docs.md` with:

1. `## Result` — a concise description of the documentation update.
2. `## Changed files` — every changed `docs/**` path, one per line, or `None`
   for a no-op.
3. `## Validation` — the consistency checks performed using read-only tools.

End the file with `<!-- COMPLETE -->`.

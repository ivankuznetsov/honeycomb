# Inspect documentation impact

Inspect only the source and documentation files supplied in this task
workspace. Do not use shell commands, network access, secrets, or files outside
the workspace.

Write `inspect.md` with:

1. `## Relevant source paths` — the supplied source files whose behavior or
   public interface affects documentation.
2. `## Documentation targets` — existing or proposed paths below `docs/`.
3. `## Rationale` — a concise explanation of the required documentation
   change, or `No documentation update required` when the supplied set is
   empty or irrelevant.
4. `## Handoff` — a bounded YAML block with only `source_paths`, `docs_paths`,
   and `rationale`.

End the file with `<!-- COMPLETE -->`. Keep each path repository-relative,
deduplicated, and free of `..` traversal. Do not edit documentation in this
stage.

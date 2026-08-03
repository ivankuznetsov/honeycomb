## [2026-08-02T20:05:00Z] root-cause-repair - pin live target-context support

- Updated the unpublished candidate's native Hive execution pin to `83ac363cb761a41345798ca05ad5f704c60b9795`, which preserves semantic blocked outcomes and exposes an explicitly unbounded managed actor's owning project as runner context.
- Kept released package compatibility pins unchanged. The new pin is required by the live acceptance run after Codex correctly refused to edit a target omitted from its explicit workspace roots.

# Bench Git root resolution

**Area:** package catalog and security lint

**Action:** Replaced the four Bench stage scripts' fixed parent-directory
traversal with source-worktree discovery by asking Git for the nested
`.hive-state` checkout, verifying it, and using its containing directory. Each
stage still verifies
`harness/hive_run.rb` before running.

**Result:** Removed all twelve blocking parent-traversal findings and their
obsolete exact suppression requests while preserving the benchmark harness
lookup across changes to Hive task-directory depth.

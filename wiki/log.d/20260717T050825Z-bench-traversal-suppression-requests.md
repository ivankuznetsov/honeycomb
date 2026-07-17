# Bench traversal suppression requests

**Date:** 2026-07-17

**Action:** Added exact security-lint suppression requests for the twelve Bench
findings produced by its canonical Hive package-to-repository anchor.

**Why:** Four guarded stage scripts resolve `../../../..` to the source
repository root and repeat that fixed anchor in diagnostics. The source package
requires that behavior, while policy requires every parent-traversal match to
remain hard until a trusted maintainer approves its exact fingerprint.

**Boundary:** The requests neither hide nor downgrade findings, grant new
permissions, or substitute for the two independent approvals required by this
high-risk package.

# Security-lint command classification

**Date:** 2026-07-17

**Action:** Removed false hard findings from workflow permission descriptors,
shell option setup, embedded Ruby environment-array construction, anchored
regular expressions, wildcard secret declarations, and hexadecimal digests.

**Why:** Real seed packages exercised legitimate instruction and permission
surfaces that the protected analyzer classified as commands, environment
dumps, absolute paths, undeclared secrets, or phone-like PII. The narrower
classification keeps genuine traversal, environment-dump, absolute-path,
secret, and broad-permission findings intact.

**Verification:** Added focused regression coverage and exercised the revised
analyzer against both seed packages before running the complete test suite.

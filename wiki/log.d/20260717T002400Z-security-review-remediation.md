# Security review remediation

**Date:** 2026-07-17

**Action:** Hardened the fork-safe security-lint and approval boundary after a
full adversarial review.

- Made instruction analysis extension-independent, added unfenced command and
  mixed dynamic-destination coverage, and bounded command/host/finding work.
- Required complete GitHub pull file lists, exact base history, current source
  runs, protected policy files, and status-first reporting.
- Bound listing decisions to the latest exact-head review, preserved renewed
  decisions append-only, and implemented trusted exact-suppression finalization.
- Aligned public identity schemas with runtime SHA, SemVer, URL, workflow, and
  command-kind constraints and added subprocess/ZIP/redirect safety tests.

**Documentation:** Updated `docs/SECURITY_LINT_CI.md`, `wiki/architecture.md`,
`wiki/command-api-surface.md`, and `wiki/security-review-contract.md`.

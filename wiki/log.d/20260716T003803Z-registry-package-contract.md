# Registry package and catalog contract shipped

**Date:** 2026-07-16

**Action:** Added the independent `honeycomb-manifest/v1` immutable version
layout, strict offline Ruby schema/path/permission/integrity primitives, atomic
canonical manifest generation and check mode, read-only human/JSON validation
with optional strict Hive compatibility, normalized dual-review evidence, and
deterministic approval-gated `honeycomb-catalog/v1` generation.

**Proof:** The fixture-first test suite exercises generation, drift, exact file
coverage, unsafe YAML/path/symlink/special-file boundaries, SemVer ambiguity,
Hive runtime states, evidence omission/staleness, empty-root artifacts, and
locale/timezone determinism without network access.

**Documentation:** Published `docs/PACKAGE_FORMAT.md`, updated README command
entrypoints, and refreshed architecture, command, decision, dependency, gap,
package/catalog, and security-review wiki context. Production review evidence
persistence remains explicitly owned by task 1849.

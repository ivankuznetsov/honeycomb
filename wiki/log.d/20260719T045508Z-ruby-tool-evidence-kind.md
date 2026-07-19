## 2026-07-19 — Admit Ruby package-tool evidence

- Aligned the strict runtime evidence contract and public JSON Schema with the
  existing inert Ruby package-tool extractor.
- Added `ruby` as an explicit command-origin kind while leaving the extracted
  sinks, policy checks, redaction, and fail-closed behavior unchanged.
- Added regression coverage that round-trips Ruby tool evidence through both
  the production contract and checked-in schema.

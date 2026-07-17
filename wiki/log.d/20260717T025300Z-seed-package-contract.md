# 2026-07-17: Seed package and bootstrap evidence contracts

- Added immutable `bench` and `docs-sync` v0.1.0 package payloads with
  generated manifests and tamper/provenance coverage.
- Fixed the protected normalized evidence location at
  `honeycomb-evidence:normalized/listing-evidence-v1.json`.
- Preserved registry-original behavior in a real source commit for the final
  manifest to cite without a self-referential Git identity.
- Bound Docs Sync writes to its state files and repository `docs/**`; listing
  remains gated on a compatible Hive release and genuine trust evidence.

# Architecture

## Repository evidence

- `lib/honeycomb_registry/validator.rb:24` is the package validation boundary.
- `lib/honeycomb_registry/catalog.rb:32` owns catalog projection.

## Constraints and tradeoffs

Keep immutable bytes and fail closed on provenance mismatch. This trades a
larger retained snapshot for reproducible task execution and auditability.

## Components and data flow

Registry -> installer -> pinned task -> mapped actor -> terminal artifact.
The configuration digest and package digest travel together through that flow.

## Reviewer resolution

- Constraints reviewer: resolved by pinning installation configuration.
- Operations reviewer: resolved with a fail-closed, immutable package-tool root.

# Architecture

## Outcome, scope, and constraints

Produce a reproducible package-to-task architecture without changing the
registry trust boundary. Success means every actor runs from immutable package
and configuration pins; catalog publication remains out of scope.

## Repository evidence

- `lib/honeycomb_registry/validator.rb:24` is the package validation boundary.
- `lib/honeycomb_registry/catalog.rb:32` owns catalog projection.
- The external threat model follows [OWASP prompt-injection guidance](https://owasp.org/www-project-top-10-for-large-language-model-applications/).

## Constraints and tradeoffs

Keep immutable bytes and fail closed on provenance mismatch. This trades a
larger retained snapshot for reproducible task execution and auditability.

## Components and data flow

Registry -> installer -> pinned task -> mapped actor -> terminal artifact.
The configuration digest and package digest travel together through that flow.

## Operations, observability, migration, and rollback

Log the immutable package, catalog, and configuration digests at admission and
each stage transition. Migrate by installing the new version for new tasks;
existing tasks retain their pins. Roll back by selecting the prior listed
version without rewriting active tasks.

## Test plan

- Verify manifest hashes and registry-original source bytes.
- Execute installation, task creation, council revision, and bounded fallback.
- Deny repository reads to the public-web actor.

## Decisions needing owner input

- Decide when provider-backed evidence is sufficient for catalog publication;
  the safe default is to keep this version unlisted.

## Reviewer findings

| Finding | Status | Reason | Section |
| --- | --- | --- | --- |
| Pin installation configuration | resolved | The digest travels with the task. | Components and data flow |
| Prove provider-backed execution | deferred | Publication remains owner-gated. | Decisions needing owner input |

<!-- COMPLETE -->

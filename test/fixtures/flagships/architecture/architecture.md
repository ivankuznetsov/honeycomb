# Architecture

## Outcome, scope, and constraints

Produce a reproducible package-to-task architecture without changing the
registry trust boundary. Success means every actor runs from immutable package
and configuration pins; catalog publication remains out of scope. The design
does not add a second installer or permit active tasks to change package bytes.

## Repository evidence

- `lib/honeycomb_registry/validator.rb:24` is the package validation boundary.
- `lib/honeycomb_registry/catalog.rb:32` owns catalog projection.
- The external threat model follows [OWASP prompt-injection guidance](https://owasp.org/www-project-top-10-for-large-language-model-applications/).

## Constraints and tradeoffs

Keep immutable bytes and fail closed on provenance mismatch. This trades a
larger retained snapshot for reproducible task execution and auditability.

## Selected design and component contracts

- The registry owns immutable package bytes and exposes a versioned read
  interface to the installer. It depends only on validated source metadata.
- The installer owns task materialization and accepts a package identity plus
  configuration digest. It depends on the registry but never rewrites it.
- The pinned task owns execution state and exposes immutable package and agent
  mappings to each actor. This keeps provenance local and auditable.

These boundaries are selected because they preserve the existing trust model
while making the installed task reproducible; a mutable shared package cache
was rejected because it could silently change an active task.

## Ordered data and control flow

1. The installer asks the registry for validated package bytes and records both
   package and configuration digests in the task.
2. The scheduler loads those pins before it invokes the mapped actor.
3. The actor returns the terminal artifact and the scheduler records its marker.
4. If a digest is absent or mismatched, control stops before actor execution and
   the task reports a provenance failure rather than using fallback bytes.

Data therefore flows registry -> installer -> pinned task -> mapped actor ->
terminal artifact, while admission and failure control flow in the reverse
direction through explicit status markers.

## Security

Validate source bytes before installation, keep credentials outside artifacts,
and deny repository reads to the networked public-web actor. A provenance
mismatch fails closed before any untrusted package instruction executes.

## Operations, observability, migration, and rollback

Log the immutable package, catalog, and configuration digests at admission and
each stage transition. Migrate by installing the new version for new tasks;
existing tasks retain their pins. Roll out to one new task first, verify its
recorded digests and terminal marker, then make the version the default. Roll
back by selecting the prior listed version without rewriting active tasks.

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
| Pin installation configuration | resolved | The digest travels with the task. | [Selected design and component contracts](#selected-design-and-component-contracts) |
| Prove provider-backed execution | deferred | Publication remains owner-gated. | [Decisions needing owner input](#decisions-needing-owner-input) |

<!-- COMPLETE -->

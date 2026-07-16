# Security Review Contract

Registry presence is the review gate. Structural validation alone never lists a
honeycomb.

## Security-lint producer

The shipped `pull_request` analyzer has only `contents: read`, checks out fork
content solely after a fresh `safe-to-validate` label event, and never executes
submitted instructions. It emits strict redacted
`honeycomb.security-lint/v1` evidence bound to `release_sha256`, the exact PR
`head_sha`, workflow run/attempt, and a content digest.

The separate `workflow_run` reporter runs default-branch code with metadata-only
write permissions. It verifies the current head and hostile artifact before
writing the authoritative `honeycomb/security-lint` status or one bot-owned
sticky comment. Synchronize/reopen evidence is pending/expired and removes the
gate label. Protected analyzer/validator/policy/schema/workflow changes refuse a
pass and must land separately.

## Normalized reader boundary

`honeycomb-catalog --evidence PATH` accepts
`honeycomb-listing-evidence/v1`. Each record identifies package name/version and
tier, with independent lint and approval verdicts. Passing/approved verdicts
carry:

- the current generated manifest `release_sha256`;
- the same exact registry review `head_sha`;
- RFC 3339 audit times;
- the human reviewer and review URL for approval.

The reader is strict about object keys, JSON duplicate keys, status values,
hashes, timestamps, URLs, duplicate records, and discovered package identity.
Missing, pending, failed, or denied gates omit. Malformed, stale, or
contradictory identity aborts all catalog output.

## Ownership boundary

This repository owns the normalized reader and fixtures. Security lint now owns
lint execution, sticky PR evidence, invalidation, and
`HoneycombSecurityLint::ListingEvidenceAdapter`, which converts strict lint plus
approval records into the existing reader meaning without reimplementing
catalog filtering.

Task 1850 still owns the approval issuer/storage channel, reviewer/trust policy,
signing/attestation decisions, promotion, demotion, advisories, yanking, and
revocation. Those are not implicit v1 fields.

Exact approved suppressions remain visible and are verified by reconstructing
the preliminary lint digest. Broad, orphaned, stale, or mismatched suppression
approvals fail closed before catalog invocation.

## Compatibility gate

Registry structure and permission derivation are standalone. CI additionally
invokes `honeycomb-validate --require-hive` with the pinned supported Hive
runtime. Hive absence, an installed version below `hive_min_version`, or public
descriptor parser rejection is an error. Local non-strict absence is only a
warning.

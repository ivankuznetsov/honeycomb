# Security Review Contract

Registry presence is the review gate. Structural validation alone never lists a
honeycomb.

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

This repository owns the normalized reader and fixtures. Task 1849 owns the
production writer/persistence location, lint execution, sticky PR evidence,
approval collection, and invalidation. It may emit the reader format directly
or adapt a private format at invocation time; it must not introduce a second
catalog authorization meaning.

Task 1850 owns reviewer/trust policy, signing/attestation decisions, promotion,
demotion, advisories, yanking, and revocation. Those are not implicit v1 fields.

## Compatibility gate

Registry structure and permission derivation are standalone. CI additionally
invokes `honeycomb-validate --require-hive` with the pinned supported Hive
runtime. Hive absence, an installed version below `hive_min_version`, or public
descriptor parser rejection is an error. Local non-strict absence is only a
warning.

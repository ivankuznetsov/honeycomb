# Honeycomb trust model

This document is the canonical public policy for honeycomb trust tiers,
release proof, and catalog lifecycle states. The package and evidence field
definitions remain authoritative in the [package format](PACKAGE_FORMAT.md).

## Assurance boundary

A trust tier records evidence about one immutable honeycomb version. It is not
a guarantee that the version is safe, an endorsement of its purpose, or a
substitute for reading its requested permissions. A Verified honeycomb with
`permission_risk: high` is still high risk. Community publishers need the
high-risk independent-review gate; a canonical first-party release may instead
carry an explicit repository-owner publication decision.

The catalog keeps these axes independent:

| Axis | Catalog fields | Meaning |
|---|---|---|
| Release and current tier | `release_tier`, `current_tier` | Evidence held at release and the registry's current classification. |
| Permission risk | `permission_risk`, `permissions` | The generated worst-case capability, network, filesystem, and secret request. |
| Lifecycle | `state`, `discoverable`, `exact_resolution` | Whether discovery and exact version resolution are allowed now. |
| Release proof | `verification` | Digest-bound signature and build-provenance evidence for a Verified version. |
| Audit trail | `history`, `advisories` | Ordered tier/state decisions and public safety notices. |

Neither automated security lint, a designated maintainer approval, a public
community review, nor release verification can replace any of the others.
Catalog listing requires current passing lint and the required current
maintainer approvals for the same `release_sha256` and `head_sha`. Community
reviews are informational. Verified release proof is an additional promotion
requirement.

## Community

Community is the initial tier for a listed version. A Community version must
have:

- a valid immutable `honeycomb-manifest/v1` package;
- current passing security-lint evidence for its exact `release_sha256` and
  pull-request `head_sha`; and
- the required eligible-maintainer approval records bound to those same
  identities and the reviewed lint `evidence_digest`.

Under independent authority, low- and moderate-risk versions need at least one
current eligible-maintainer approval and a `risk: high` version needs two
distinct eligible maintainers. A canonical first-party release may instead use
one protected `repository_owner` approval at any risk when the admin namespace
owner authored the pull request, current lint passes without suppressions, and
the exact responsibility acknowledgement is recorded at an immutable Actions
audit URL. This records ownership accountability, not independent review or a
safety claim. A current denial makes the version ineligible. Signing is
encouraged for Community versions but is optional.

## Verified

Verified is a manual, version-specific promotion available to community
publishers with a stable public identity and provenance history. It means the
registry recorded stronger continuity and release evidence; it does not mean
the instructions or their permissions are safe.

A candidate version may be promoted only when maintainers record all of the
following:

1. The publisher has at least two clean listed releases.
2. Publisher identity, repository ownership, and upstream provenance are
   stable and publicly traceable.
3. No unresolved security or provenance report undermines the candidate.
4. The immutable release has matching keyless signature and GitHub Actions
   artifact-attestation evidence.
5. The candidate satisfies its current lint and independent maintainer-approval
   gate, including two distinct maintainers when `permission_risk` is `high`;
   repository-owner authority does not satisfy Verified promotion.
6. A maintainer explicitly approves promotion of this exact version.

A clean release is a listed release whose required lint and approvals remained
valid and which has no unresolved substantiated security report. It is not a
claim that no vulnerability existed.

Promotion sets the candidate's `release_tier` and `current_tier` to `verified`
and records the release proof. It never promotes a publisher or future version
implicitly. A later version, changed instruction, or changed permission request
must repeat the listing and release-proof checks.

Failure of any promotion check leaves the request pending; it is not silently
treated as a successful Community release. A Community listing may proceed
separately only when its own current gate is complete.

## Verified release proof

Verified archives use keyless
[Sigstore/cosign identity signing](https://docs.sigstore.dev/cosign/signing/overview/)
and [GitHub Actions artifact
attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).
The registry verifies identity and digest, not possession of a shared,
long-lived registry signing key.

The immutable archive contains `manifest.yml` and exactly the payload recorded
by the manifest's sorted `files` map, including `workflow.yml`, `README.md`, and
every instruction file. Catalog `verification.archive_sha256` is the canonical
archive identity derived from `release_sha256` and that complete file map.
Release evidence also records:

- `signature.identity`, the exact GitHub Actions workflow identity;
- `signature.issuer`, which must be
  `https://token.actions.githubusercontent.com`;
- `signature.url`, the transparency/signature reference;
- `attestation.repository`, `attestation.workflow`, and `attestation.url`,
  binding build provenance to the same GitHub repository and workflow; and
- `verified_at`, the verification time.

Maintainers verify the archive digest and signer identity with cosign and
verify the artifact attestation against the expected repository/workflow before
promotion. GitHub's [artifact-attestation verification
guidance](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
describes that identity-and-digest check.

A missing member, extra member, digest mismatch, unexpected signer or issuer,
wrong attestation repository/workflow, or invalid reference fails the Verified
evidence check. The catalog generator rejects contradictory Verified evidence;
it does not silently downgrade the record to Community.

These identities must remain distinct:

- `source_sha`: the upstream provenance revision (`source.revision` in the
  manifest);
- `release_sha256`: the immutable honeycomb package fingerprint;
- `head_sha`: the exact registry pull-request revision reviewed by lint and
  maintainers;
- `evidence_digest`: the reviewed security-lint artifact digest; and
- `archive_sha256`: the signed immutable archive identity.

## Catalog lifecycle states

Lifecycle state is independent of Community/Verified tier and permission risk.
Every version that once satisfied the dual listing gate remains in the
canonical audit catalog.

| `state` | Discovery and default/new install | Exact pinned resolution | Policy use |
|---|---|---|---|
| `listed` | Included | Allowed | Current listing at its `current_tier`. |
| `soft_hidden` | Excluded immediately | Allowed unless separately revoked | Temporary protection while a critical credible report is investigated. |
| `yanked` | Excluded | Allowed | Ordinary delisting that preserves history and existing exact pins. |
| `revoked` | Excluded | Blocked | Exceptional response when continued distribution would create material harm; at least one public advisory is required. |

`soft_hidden` is not a waiting period: maintainers apply it immediately when a
critical report is credible enough to investigate. A yank is the normal
delisting action for policy, quality, ownership, or provenance concerns that do
not justify breaking exact pins. Revocation is reserved for material harm from
continued distribution. Installers must fail closed for the exact revoked
version and surface its catalog `advisories`.

Relisting requires resolution of the report or policy concern and fresh current
lint/approval evidence wherever security-relevant content or identity changed.
History and any notice needed by installed users remain auditable.

Reporting, response targets, notifications, and state-selection criteria are
defined in the [root security policy](../SECURITY.md).

## Suspension, demotion, and history

Maintainers may suspend discovery, demote `current_tier`, yank, or revoke after
loss of publisher ownership, provenance continuity, signing confidence, or
security confidence. The action is prospective and recorded in `history` with
the actor, reason, time, and decision URL.

`release_tier` and the version's `verification` preserve what was recorded for
the immutable release. `current_tier` and `state` describe current catalog
treatment. Demotion therefore does not rewrite the historic tier of an already
installed artifact, while an old Verified release never grants Verified status
to a new version or current publisher automatically.

## Permanent openness commitment

The honeycomb registry, package schemas, submission rules, lint and listing
gate, trust policy, community-review process, catalog projection, advisories,
and distribution behavior will remain open source. Policy decisions that
affect listing, moderation, promotion, demotion, yanking, or revocation must
remain publicly auditable without exposing a confidential vulnerability.

Only deployment secrets, private operations configuration, and narrowly scoped
anti-abuse heuristics whose publication would materially enable evasion may be
kept private. Those exceptions do not permit a private listing standard,
undisclosed trust tier, secret reviewer rule, or closed distribution process.

The operational lint/approval boundary is documented in [Security Lint
CI](SECURITY_LINT_CI.md). Contributor review steps and appeals are defined in
[the root contribution policy](../CONTRIBUTING.md), and public review policy is
defined separately in [community reviews](REVIEWS.md).

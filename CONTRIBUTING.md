# Contributing honeycombs

This is the canonical public policy for submitting, reviewing, promoting, and
appealing a honeycomb listing. The [trust model](docs/TRUST.md) defines tiers
and lifecycle states; [community reviews](docs/REVIEWS.md) are a separate,
informational process.

## Prepare an immutable version

Every submission adds a new `packages/<name>/<semver>/` directory that follows
the [honeycomb package format](docs/PACKAGE_FORMAT.md). A merged version
directory is immutable. Publish a new SemVer version for every fix or change;
do not edit a listed version in place. The exact-base security gate rejects any
modification, rename, or deletion beneath a version directory that already
exists in the pull request's base revision; only a wholly new SemVer directory
can enter the listing flow.

Before opening a pull request:

1. Declare the upstream source URL and exact `source.revision` provenance
   commit. This becomes catalog `source_sha`.
2. Request the least privilege needed by every stage and reviewer. Avoid shell,
   secrets, repository write access, broad filesystem scope, and unrestricted
   network access unless the honeycomb cannot work without them.
3. Include `workflow.yml`, `README.md`, every referenced instruction file, and
   author-owned manifest metadata.
4. Generate the manifest, then check the generated file and the complete
   package:

   ```sh
   ruby script/honeycomb-manifest packages/<name>/<version>
   ruby script/honeycomb-manifest --check packages/<name>/<version>
   ruby script/honeycomb-validate packages/<name>/<version>
   ```

5. Inspect the generated `permissions`, `files`, and `release_sha256`. Generated
   values must not be hand-edited or narrowed to make review easier.
6. Keep community review files outside the immutable version directory. They
   belong under `reviews/<name>/<version>/<github-user>.md` and never satisfy
   listing approval.

The registry checks the package path, strict schema, instruction references,
permission projection, complete file map, file digests, and canonical manifest.
Validation success is necessary but never sufficient for listing.

## Keep trusted tooling separate

A pull request that submits a honeycomb must not also modify the code that will
assess it. Land changes to these trusted surfaces in a separate pull request
before relying on them:

- `.github/workflows/`;
- `lib/honeycomb_security_lint.rb` or `lib/honeycomb_security_lint/`;
- `lib/honeycomb_registry.rb` or `lib/honeycomb_registry/`;
- the `honeycomb-security-lint`, `honeycomb-security-lint-report`,
  `honeycomb-listing-approval`, `honeycomb-validate`, `honeycomb-manifest`, or
  `honeycomb-catalog`, or `honeycomb-reviews` scripts;
- files under `policy/`; and
- security, listing-evidence, approval, manifest, or catalog schemas under
  `schemas/`.

The trusted reporter and approval issuer reject a combined change. This split
prevents a submission from redefining the validator, lint policy, approval
meaning, or suppression rules used to approve itself.

## Exact-SHA review lifecycle

Honeycomb review has four distinct records:

1. generated package validation and `release_sha256`;
2. automated security-lint evidence for one exact pull-request `head_sha`;
3. a designated eligible-maintainer approval bound to that release, head, and
   lint `evidence_digest`; and
4. optional informational community reviews and, for Verified promotion,
   separate signed-release proof.

Only items 2 and 3 together can satisfy the catalog listing gate.

The fork-safe pull-request flow is:

1. On open, synchronize, or reopen, the authoritative
   `honeycomb/security-lint` status is pending. Submitted instructions are not
   executed.
2. A maintainer reads the changed-file list and applies `safe-to-validate` to
   that exact `head_sha`.
3. The read-only analyzer checks out the fork head, validates and scans the
   submitted bytes, and emits redacted `honeycomb.security-lint/v1` evidence.
4. Default-branch reporter code verifies the artifact, current pull-request
   head, workflow run, and digest before publishing the authoritative status.
5. An eligible maintainer reads the complete security-relevant diff and submits
   a GitHub pull-request review on the same head.
6. The protected listing-approval workflow re-verifies maintainer eligibility,
   the current review, authoritative status/run, release identity, head SHA,
   and evidence digest. It appends immutable approval evidence on the protected
   `honeycomb-evidence` branch.
7. The production listing-evidence exporter and catalog reader include the
   version only when lint passes and the complete current approval set agrees
   on `release_sha256` and `head_sha`.

The operational trust split and suppression flow are detailed in [Security
Lint CI](docs/SECURITY_LINT_CI.md).

## What maintainers review

The security-relevant diff includes all submitted package bytes, especially:

- `workflow.yml`, every instruction or prompt, and executable examples in
  `README.md`;
- manifest permission risk, capabilities, network hosts, filesystem read/write
  scopes, secrets, source provenance, and extension-based suppression requests;
- generated file-map and package-fingerprint changes; and
- any generator, validator, lint policy, schema, workflow, or suppression logic
  changed in the separate trusted-tooling pull request.

Reviewers compare requested access with the stated behavior and require least
privilege. They inspect commands and prompt intent, undeclared hosts, secret or
personal-data handling, persistence, destructive behavior, source/ownership
continuity, and whether the README describes the real consequences of running
the honeycomb.

Any new push invalidates the prior `safe-to-validate` gate and authoritative
evidence for the old head. A changed instruction, executable example, source,
capability, host, secret, shell request, filesystem scope, or suppression also
changes security-relevant identity. Listing returns to pending until a
maintainer applies a fresh label and current lint and approval evidence is
issued for the new `head_sha`. A clean result for an earlier SHA can never
authorize the current head.

## Maintainer counts and conflicts

Eligible maintainers are repository collaborators with write, maintain, or
admin permission. Independent authority mechanically rejects approval by the
pull-request submitter, and one GitHub identity cannot count twice. A
maintainer who authored, published, or controls the submitted honeycomb under
another account must disclose that relationship and recuse; the current
manifest does not carry a verifiable GitHub publisher identity, so this broader
conflict rule is enforced by maintainer review rather than inferred from
display-name or URL metadata.

- The v1 catalog gate requires one current eligible-maintainer approval for a
  low- or moderate-risk Community version.
- Under independent authority, every `permission_risk: high` version requires
  two distinct eligible maintainers. If the second reviewer is unavailable,
  the version remains pending.
- A first-party release authored by the repository owner in the canonical
  repository may instead use `repository_owner` authority. The protected
  issuer requires the dispatching identity to be the admin namespace owner and
  pull-request author, requires current passing lint, rejects every suppression,
  requires the exact responsibility acknowledgement plus non-empty audit notes,
  and records the trusted Actions run URL. One such owner record satisfies the
  Community listing count at any permission risk. It is an explicit publication
  decision, not independent review or a safety endorsement.
- `repository_owner` authority is not available to forks, community publishers,
  non-admin collaborators, denials, suppression approvals, or Verified
  promotion requirements.
- A denial from any current eligible reviewer makes the version ineligible
  until that reviewer records a newer current decision or the concern is
  otherwise resolved through the normal evidence flow.

The generated manifest is the only risk classifier. Shell, secrets, repository
write, or unrestricted network access are common high-risk examples, but prose
or a reviewer cannot override the normalized `permissions.risk` value.

## Review targets

Maintainers aim to acknowledge a complete listing request within **two business
days** and to complete an ordinary review within **seven business days**. These
are best-effort targets, not guarantees or automatic approvals. They start only
when the required package and provenance information is present.

High-risk, conflict-blocked, dependency-blocked, or unusually complex reviews
have no promised completion time. Silence, label age, or either target expiring
never satisfies lint or maintainer approval.

## Verified promotion and later changes

After at least two clean listed releases, a publisher may request manual
Verified promotion for one candidate version. The request must identify the
candidate `name`, `version`, `source_sha`, `release_sha256`, and reviewed
`head_sha`, and link the two qualifying releases, publisher/provenance evidence,
keyless signature, GitHub Actions attestation, and current maintainer approvals.

The complete promotion criteria are in [the trust model](docs/TRUST.md#verified).
Promotion applies only to the named version. New instructions, a new release,
an ownership transfer, or changed provenance cannot inherit it. Maintainers may
suspend discovery or demote current status when provenance, ownership,
signing, or security confidence changes, while preserving historic release
evidence.

## Appeals

A contributor, reviewer, publisher, reporter, or affected user may appeal a
listing refusal, review moderation decision, promotion/demotion, yank, or
revocation. Open a new issue or pull request that contains only information safe
for a public repository and includes:

- the challenged decision and its public URL;
- honeycomb `name` and `version`, plus `source_sha`, `release_sha256`, and
  `head_sha` when relevant;
- the requested remedy;
- new evidence or the specific policy interpretation being challenged; and
- the appellant's relationship to the honeycomb and any conflict of interest.

If the appeal contains vulnerability details, secrets, exploit steps, private
data, or unredacted logs, use the [private channel in the security
policy](SECURITY.md#report-privately) instead of a public issue.

An appeal does not restore discovery, resolve an approval, republish a moderated
review, remove an advisory, promote a version, or relax a soft-hide, yank, or
revocation automatically. Active safety restrictions remain in force until a
recorded decision changes them. When available, a maintainer who did not make
the original decision reviews the appeal. If no independent maintainer is
available, the available maintainer documents the reconsideration and the
conflict. Appeals have no resolution-time guarantee.

Public review verdicts remain evidence and opinion only. See [community
reviews](docs/REVIEWS.md) for their separate contribution and moderation rules.

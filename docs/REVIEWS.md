# Honeycomb community reviews

This document is the canonical public policy and record format for community
reviews. Community reviews are evidence-backed, informational records. They
never satisfy security lint, designated maintainer approval, permission
classification, Community listing, or Verified promotion.

## Location and identity

Review files live outside immutable honeycomb packages:

```text
reviews/<name>/<version>/<github-user>.md
```

The path is versioned because every review concerns one immutable release. The
filename and front-matter `reviewer` must match the authenticated GitHub user
who opens the pull request. A maintainer may accept a verifiable delegation
only by recording the original identity, delegated identity, evidence, and
reason in the review pull request. Delegation does not permit an anonymous or
shared identity.

Reviews never live under `packages/<name>/<version>/`. Adding, correcting,
moderating, or removing one therefore cannot change manifest `files`,
`release_sha256`, signed `archive_sha256`, lint evidence, or designated listing
approval.

## Record format

Every review is UTF-8 Markdown with strict YAML front matter followed by the
four exact second-level headings shown below. Front-matter keys are exact;
unknown or duplicate keys are rejected.

```markdown
---
reviewer: "github-user"
name: "example"
version: "1.0.0"
source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
release_sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
head_sha: "cccccccccccccccccccccccccccccccccccccccc"
reviewed_at: "2026-07-17"
verdict: "approve-with-notes"
conflict_of_interest: "none"
---
# Community review

## Scope reviewed

Name the exact files, behaviors, provenance, and tests reviewed, plus anything
not reviewed.

## Permission observations

Compare the generated risk, capabilities, hosts, filesystem scopes, and secrets
with the behavior you observed.

## Findings

Give reproducible evidence with file paths, commands safe to publish, and links.
Write `None observed` when there are no findings; do not leave this section blank.

## Rationale

Explain how the scope, permission observations, and findings support the verdict.
```

The identity fields deliberately reuse the catalog and listing contracts:

- `name` and `version` identify the reviewed honeycomb release;
- `source_sha` is the upstream provenance revision;
- `release_sha256` is the immutable package fingerprint;
- `head_sha` is the exact registry pull-request revision examined; and
- `reviewer` is the public GitHub identity responsible for the review.

SHAs are lowercase 40- or 64-character hexadecimal revisions as allowed by the
landed contracts; SHA-256 values are exactly 64 lowercase hexadecimal
characters. `reviewed_at` is an ISO 8601 calendar date (`YYYY-MM-DD`).
`conflict_of_interest` is always present: use `none` or disclose employment,
authorship, financial, personal, competitive, or other relationships that may
reasonably affect the review.

Each body section must be substantive and limited to information safe to place
in a public repository. Send vulnerability details, secrets, exploit steps,
private data, and unredacted logs through the [private channel in the root
security policy](../SECURITY.md#report-privately) instead.

## Verdicts

Exactly four verdicts are allowed:

| Verdict | Meaning |
|---|---|
| `approve` | No material concern was found within the stated scope. |
| `approve-with-notes` | The reviewer found non-blocking limitations or advice that users should read. |
| `warn` | Evidence shows material risk or mismatch; users should understand and mitigate it before use. |
| `reject` | Evidence shows the version should not be used in the reviewed context. |

A negative `warn` or `reject` is as valid as a positive review when its scope,
evidence, conflict disclosure, and rationale meet this contract. A verdict is
the reviewer's conclusion, not a registry trust score or maintainer listing
decision.

Checked examples cover [`approve`](../test/fixtures/documentation/reviews/example/1.0.0/alice-reviewer.md),
[`approve-with-notes`](../test/fixtures/documentation/reviews/example/1.0.0/bob-reviewer.md),
[`warn`](../test/fixtures/documentation/reviews/example/1.0.0/carol-reviewer.md),
and [`reject`](../test/fixtures/documentation/reviews/example/1.0.0/dave-reviewer.md).

## Submit or correct a review

Any authenticated GitHub user may propose a review by pull request. Submit one
reviewer file per honeycomb version and keep claims within the declared scope.
Link public evidence directly where practical. Do not copy another reviewer or
use multiple accounts to manufacture consensus.

Correct a review with a normal follow-up pull request that changes the same
file. Update `reviewed_at` when the conclusion or evidence changes and explain
the correction in the pull request. A newer review does not erase the previous
text from normal Git history.

Catalog `reviews_url` points to the external
`reviews/<name>/<version>/` namespace. A site may link or enumerate those files,
but it must not turn verdicts, review counts, or reviewer popularity into an
aggregate score. One or many `approve` reviews do not change listability,
`release_tier`, `current_tier`, `permission_risk`, lifecycle `state`, or the
required designated-maintainer approvals in `listing_approval`.

## Moderation

A maintainer checks identity, record shape, evidence, relevance, scope, and
public-safety boundaries before merging a review. Moderation is not an
endorsement of the verdict. Maintainers may request edits or reject content
that is:

- irrelevant to the identified honeycomb version or outside the stated scope;
- abusive, harassing, discriminatory, doxxing, or otherwise unsafe to publish;
- a fabricated or materially misleading claim presented as evidence;
- retaliation, coercion, brigading, impersonation, or review manipulation;
- undisclosed conflict of interest or unverifiable delegated identity; or
- confidential vulnerability information, secrets, exploit steps, private
  data, or unredacted logs that belong in private reporting.

Disagreement, an unfavorable verdict, or a publisher's preference is not a
moderation reason. Evidence-backed criticism remains eligible even when it is
strongly negative.

When correction cannot make a current-tree review safe or relevant, removal is
a normal pull request deleting the file. The commit or pull request records a
specific moderation reason. Git history is not rewritten. If repeating abusive
or sensitive content would cause further harm, the public reason summarizes
the category and decision without republishing that material.

## Appeals

Appeal a rejected, edited, or removed review through the [general appeal
process](../CONTRIBUTING.md#appeals), identifying the review path, moderation
decision, requested remedy, new evidence, and conflicts. Use [private
vulnerability reporting](../SECURITY.md#report-privately) if the appeal itself
contains confidential security details.

Filing an appeal does not republish or restore a review. The active moderation
decision remains in force until a recorded decision changes it. A maintainer
who did not make the original decision handles the appeal when one is
available; otherwise the available maintainer documents the reconsideration
and conflict. No resolution-time guarantee applies.

For the independent tier, permission, and lifecycle model, see the [trust
policy](TRUST.md). For the only approval process that can list a version, see
[contributing honeycombs](../CONTRIBUTING.md#exact-sha-review-lifecycle).

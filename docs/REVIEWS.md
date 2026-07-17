# Honeycomb community reviews

This document is the canonical public policy for community reviews. Community
reviews are evidence-backed, informational records. They never satisfy
security lint, designated maintainer approval, permission classification,
Community listing, or Verified promotion.

Review files live outside immutable packages at:

```text
reviews/<name>/<version>/<github-user>.md
```

The submitting GitHub identity normally matches `<github-user>` and the review's
declared reviewer. A review uses one of exactly four verdicts: `approve`,
`approve-with-notes`, `warn`, or `reject`. Negative reviews are welcome when
they are relevant, scoped, and supported by reproducible evidence. Star ratings
and aggregate trust scores are not part of the review contract.

The structured record format, examples, moderation criteria, correction and
removal process, and appeal route are defined in the sections added with the
review fixture contract. Until that contract lands, do not add production
community review records.

For listing and designated approval requirements, see [contributing
honeycombs](../CONTRIBUTING.md). For the independent tier, risk, and lifecycle
axes, see the [trust model](TRUST.md).

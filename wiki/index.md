# Project Wiki

This wiki is maintained for coding agents. Read it before planning,
implementation, review, or debugging work, and update it when project facts
change.

## Core Pages

- [[architecture]] - system shape, runtime flows, and important modules.
- [[command-api-surface]] - documented commands, catalog surface, and current
  implementation status.
- [[decisions]] - durable design decisions and tradeoffs.
- [[dependencies]] - runtime, development, and service dependencies.
- [[package-catalog-contract]] - shipped package, manifest, evidence, and catalog
  contracts.
- [[security-review-contract]] - identity binding and boundary with listing CI.
- [[submission-canary]] - maintainer-dispatched bot submission used to smoke
  the real lint, non-self approval, publication, site, and Hive boundaries.
- [[gaps]] - missing, uncertain, or stale wiki coverage.

## Canonical Public Policy

- [Contributing honeycombs](../CONTRIBUTING.md) - submission, exact-SHA review,
  promotion, and appeals.
- [Security policy](../SECURITY.md) - private/public reporting and protective
  lifecycle actions.
- [Trust model](../docs/TRUST.md) - tiers, release proof, lifecycle, and
  openness.
- [Community reviews](../docs/REVIEWS.md) - structured records and moderation.

These public files are normative. Wiki pages summarize implementation facts and
link to policy rather than restating it.

## Flagship Package Status

Architecture, Writing, and SEO Content 1.0.1 packages and canonical manifests
are present under `packages/` with a Hive 0.6.0 minimum. They are agent-agnostic
and are exercised through Hive's real registry install, configuration-pin,
task-creation, Agent, Council, and package-root paths using deterministic test
agents. They are not catalog listings until Hive 0.6.0 is released and protected
lint evidence plus independent approvals exist.

## Update Protocol

- Update affected pages when code behavior, architecture, commands, or
  dependencies change.
- Add a new `wiki/log.d/<timestamp>-<slug>.md` fragment after every wiki update,
  but do not edit the compiled `wiki/log.md` in feature PRs.
- Record uncertainty in [[gaps]] instead of inventing facts.

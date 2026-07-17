# Honeycomb security policy

This is the canonical public policy for reporting honeycomb vulnerabilities,
requesting delisting, and handling soft-hides, yanks, revocations,
notifications, and appeals.

## Report privately

Report vulnerabilities and any evidence containing secrets, exploit steps,
private data, unpublished repository content, or unredacted logs through a
private channel. Do **not** open a public issue for that material.

Use [GitHub private vulnerability
reporting](https://github.com/ivankuznetsov/honeycomb/security/advisories/new)
through the repository's enabled private report form. If GitHub is unavailable,
email `ivan@ikuznetsov.com` with the subject `honeycomb security report`. The
address is the repository owner's published security fallback; do not copy a
public mailing list or issue address.

Include, where known:

- honeycomb `name` and `version`;
- `source_sha`, `release_sha256`, reviewed `head_sha`, or archive digest;
- observed versus expected behavior and impact;
- minimal reproduction steps and affected environments;
- whether exploitation is known or ongoing;
- evidence attachments or private links; and
- your preferred contact and disclosure constraints.

Minimize live credentials and personal data. Revoke exposed credentials before
sending when doing so is safe, and use synthetic reproductions whenever
possible.

## Request public delisting

Use the [public security/delisting issue
form](https://github.com/ivankuznetsov/honeycomb/issues/new?template=security-delisting.yml) for policy, provenance,
ownership, permission, quality, or suspicious-behavior reports whose complete
contents are safe to publish. The issue, attachments, links, and comments are
public.

The public form asks for the honeycomb/version, source or package identity,
category, observed behavior, evidence links, impact, requested action,
relationship/conflicts, and an explicit safe-to-publish confirmation. Redact
private repository names, tokens, personal data, exploit details, and logs. If
redaction would prevent useful triage, report privately instead.

Maintainers may move only a safe summary into a public issue. They will not ask
a reporter to republish confidential evidence to make a delisting decision.

## Response targets

Maintainers aim to:

- acknowledge a security or delisting report within **48 hours**; and
- complete initial triage within **seven calendar days**.

These targets are not resolution deadlines or guarantees. Initial triage
determines credibility, severity, affected identities, current catalog state,
confidentiality, and the next protective action. Investigation, coordinated
disclosure, a corrected release, or an appeal may take longer.

A critical report that is credible enough to investigate triggers an immediate
`soft_hidden` state. Maintainers do not wait for the seven-day triage target or
for complete root-cause analysis before hiding it from discovery and
default/new installs.

## Protective states

Trust tier, permission risk, and lifecycle state remain independent. Protective
actions retain the version in canonical catalog history:

| Action | Catalog `state` | Discovery and default/new install | Exact pinned resolution |
|---|---|---|---|
| Normal listing | `listed` | Included | Allowed |
| Investigation hold | `soft_hidden` | Excluded immediately | Continues unless separately revoked |
| Ordinary delisting | `yanked` | Excluded | Continues |
| Material-harm response | `revoked` | Excluded | Fails closed with public advisory metadata |

### Record a protective decision

The protected normalized listing-evidence file is the durable lifecycle record.
For an emergency soft-hide, a maintainer changes the affected record's `state`
to `soft_hidden`, appends an ordered `history` transition with actor, reason,
time, and a public-safe decision URL, validates the file, regenerates
`catalog.json`, and lands both through the protected maintainer path. Yank,
revoke, relist, promotion, and demotion use the same reviewed procedure;
revocation also requires a public `advisories` record.

The listing exporter requires the current normalized evidence as `--previous`,
retains records not selected for lint refresh, and carries forward tier, state,
verification, history, and advisories for selected versions. Omitting lifecycle
state therefore cannot silently relist a protected version. The exact offline
commands and bootstrap rule are documented in [Security Lint
CI](docs/SECURITY_LINT_CI.md#suppressions-and-human-approval).

### Soft-hide

Maintainers soft-hide a critical credible report immediately while validating
impact and scope. Public catalog metadata may identify that an investigation is
active without revealing confidential facts. A soft-hide is reversible, does
not decide the report's merits, and does not by itself break an exact pin.

### Yank

Yanking is the ordinary delisting response for substantiated policy, quality,
ownership, permission, or provenance concerns where continued exact resolution
does not create material harm. Discovery, implicit latest selection, and
default/new installs exclude the version. Its history, advisories, and exact
pinned resolution remain available for audit and existing users.

### Revoke

Revocation is exceptional. Maintainers use it when continued distribution of
the exact version would create material harm, such as credential theft,
destructive behavior, or an actively exploitable package whose safe use cannot
be preserved. The catalog retains the version and requires at least one public
`advisories` record, but installers must fail the exact resolution and surface
that advisory. Revocation is never a silent deletion.

## Resolution and relisting

A false, non-applicable, or resolved report may lead to restoration of the
previous state. Relisting is a new current decision, not automatic rollback.
Where package content, permissions, source, ownership, or security-relevant
identity changed, a new immutable version and fresh current lint and designated
maintainer approvals are required. A previous clean SHA cannot authorize the
changed release.

Maintainers keep ordered state/tier `history` and any `advisories` needed for
audit or installed-user safety. Confidential report content remains private;
the public decision records only the minimum reason and evidence reference
needed to explain catalog treatment.

## Notifications

For a public advisory, yank, or revocation, maintainers notify users through:

- catalog `advisories` and lifecycle metadata consumed by discovery and
  installers;
- the repository's GitHub security-advisory channel when vulnerability
  disclosure is appropriate; and
- the repository release channel for affected published artifacts when a
  release notice is needed.

Notifications identify the honeycomb/version, severity, affected behavior,
protective state, available remediation, and public advisory URL. They do not
copy secrets, exploit-enabling details under embargo, reporter private data, or
unredacted evidence into the catalog.

## Appeals and disclosure conflicts

Listing, soft-hide, yank, revocation, promotion/demotion, and review-moderation
decisions may be appealed through the [contributor appeal
process](CONTRIBUTING.md#appeals). Use the private reporting channel above when
the appeal contains vulnerability details.

An appeal does not remove an advisory, restore discovery or exact resolution,
or weaken another active safety control. The current state remains in force
until a recorded decision changes it. A maintainer who did not make the
original decision reviews the appeal when available; otherwise the available
maintainer documents the reconsideration and conflict. There is no appeal
resolution SLA.

Reporters, publishers, reviewers, and maintainers should disclose relevant
relationships and avoid retaliation. Coordinated disclosure timing protects
users; it must not be used to suppress an evidence-backed warning indefinitely.

For exact tier and lifecycle semantics, see the [trust
model](docs/TRUST.md#catalog-lifecycle-states). For listing evidence and
reviewer requirements, see [contributing honeycombs](CONTRIBUTING.md).

# Security Review Contract

Registry presence is the review gate. Structural validation alone never lists a
honeycomb.

## Security-lint producer

The shipped `pull_request` analyzer has only `contents: read`, checks out fork
content solely after a fresh `safe-to-validate` label event, and never executes
submitted instructions. It emits strict redacted
`honeycomb.security-lint/v1` evidence bound to `release_sha256`, the exact PR
`head_sha`, workflow run/attempt, and a content digest.

Evidence and approval JSON use the registry's own sorted, UTF-8 canonical
encoder. Empty containers, escaping, indentation, and integer rendering do not
depend on the runner's Ruby `json` gem version, so a digest issued by the
GitHub analyzer is re-verifiable by the offline evidence exporter.

The separate `workflow_run` reporter runs default-branch code with metadata-only
write permissions. It verifies the current head and hostile artifact before
writing the authoritative `honeycomb/security-lint` status or one bot-owned
sticky comment. Synchronize/reopen evidence is pending/expired and removes the
gate label. Protected analyzer/validator/policy/schema/workflow changes refuse a
pass and must land separately. The reporter requires a complete GitHub changed
file list, serializes by pull request, rejects older same-head source runs, and
publishes `success` for complete diffs with no honeycomb changes so the required
context never deadlocks unrelated pull requests.

## Normalized reader boundary

`honeycomb-catalog --evidence PATH` accepts
`honeycomb-listing-evidence/v1`. Each record identifies honeycomb name/version,
release/current tier, permission risk, lifecycle state, one lint verdict, a
current reviewer-decision array, optional verification, ordered history, and
public advisories. Passing/approved verdicts carry:

- the current generated manifest `release_sha256`;
- the same exact registry review `head_sha`;
- RFC 3339 audit times;
- each human reviewer, review URL, and reviewed evidence digest.

Independent low/moderate risk requires one distinct current approval and high
risk requires two. A canonical first-party Community release may instead use
one protected repository-owner approval at any risk; a current denial blocks
eligibility. Verified evidence binds the
immutable archive identity, GitHub OIDC signer, signature reference, Actions
attestation/workflow, and verification time. Revocation requires a public
advisory. Tier, risk, lifecycle, verification, and advisory meanings do not
substitute for lint or human approval.

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

The protected listing-approval workflow owns issuance and immutable storage.
Independent authority requires an eligible non-author maintainer and that
maintainer's latest decisive GitHub review bound to the exact head.
Repository-owner authority requires the admin namespace owner to author and
dispatch a canonical-repository pull request, passing lint without suppressions,
the exact responsibility acknowledgement, audit notes, and an Actions-run audit
URL. Both require the exact authoritative status/run, redacted artifact, and
matching release/head identities. Exact requested suppressions remain available
only to independent reviewers. The issuer appends canonical records under
`honeycomb-evidence`; renewed
reviewer decisions use distinct immutable records, and export selects the latest
decision per reviewer. The offline exporter still selects exact lint snapshots.

Task 1850's public policy is shipped in [contributing
honeycombs](../CONTRIBUTING.md), the [security policy](../SECURITY.md), the
[trust model](../docs/TRUST.md), and [community
reviews](../docs/REVIEWS.md). Signing/attestation, promotion, demotion,
advisories, yanking, and revocation continue to use separate catalog contract
fields rather than implicit lint or approval meanings.

Community review records live at
`reviews/<name>/<version>/<github-user>.md`, outside package payloads and the
protected approval store. Trusted-base validation binds the record and PR
author to an already-listed base package/catalog identity without executing or
trusting submitted package/catalog code. Catalog `reviews_url` preserves
designated approval meaning, while the
nullable `community_reviews_url` points to the mutable default-branch namespace.
Designated approval audit URLs also remain under `listing_approval.reviews`.
Community verdicts have no listing authority.

Exact approved suppressions remain visible and are verified by reconstructing
the preliminary lint digest. Broad, orphaned, stale, or mismatched suppression
approvals fail closed before catalog invocation.

Instruction analysis covers README/workflow surfaces plus every UTF-8 file under
`instructions/`, including unfenced command-like lines and non-Markdown
extensions. Commands, network observations, and findings have policy budgets;
budget exhaustion is an operational error rather than truncated evidence.
Each exact tool path declared by `x-hive.tools` joins this behavior-bearing
scope even when it lives outside `instructions/`, so its shell commands,
network destinations, secret references, and deny patterns remain attributable
to the tool file. Security lint reads these files as inert bytes and never
executes them. Evidence records statically extracted Ruby tool sinks with the
`ruby` command kind, distinct from fenced, inline, plain, and YAML instruction
origins.

Derived wildcard network disclosure remains a broad-permission advisory. A
package may narrow its observed destinations for human review by giving each
concrete host an exact `x-security.network_host_reasons` entry; this cannot
authorize network capability that the workflow did not already declare, and
dynamic or unreasoned destinations still fail closed.

Workflow `permissions.tools` and `permissions.dirs` values are descriptor data,
not executable YAML instruction strings. Other YAML scalars enter command
analysis only when they are command-like. Shell option setup such as
`set -euo pipefail` and embedded-language variables named `env` are not
environment dumps. A declared secret wildcard authorizes observed secret
variable names while remaining a broad-permission advisory. Anchored regular
expression literals are not absolute paths, and hexadecimal content digests are
not phone-like PII. These exclusions preserve actual parent-traversal findings,
bare environment dumps, conventional absolute paths, and undeclared secrets.

## Compatibility gate

Registry structure and permission derivation are standalone. CI additionally
invokes `honeycomb-validate --require-hive` with the pinned supported Hive
runtime. Hive absence, an installed version below `hive_min_version`, or public
descriptor parser rejection is an error. Local non-strict absence is only a
warning.

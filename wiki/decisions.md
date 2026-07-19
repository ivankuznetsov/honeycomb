# Decisions

Record durable technical decisions here with date, context, decision, and
consequence.

## 2026-07-09: Published Workflow Packages Are Honeycombs

Context: commit `ab7861a` updated the README to use a consistent product term
for publishable Hive workflows. The Hive inbox task notes also carry the same
naming guidance.

Decision: call each published workflow package a "honeycomb" in user-facing
surfaces. The public catalog URL is `hivecli.sh/honeycombs`, and the install form
is `hive workflow install honeycomb/<name>`.

Consequence: future manifest docs, CLI output, CI comments, README catalog
sections, and review copy should use "honeycomb" for listed workflow packages.
The repository should not introduce competing terms such as "package" as the
primary user-facing name, except where implementation details require it.

## 2026-07-16: Version Directories and Generated Manifests Are the Registry Source

Context: mutable latest-only directories, hand-maintained hash summaries, and
Git-tag-only history could each make catalog identity ambiguous.

Decision: keep every release at `packages/<name>/<semver>/`. Authors own manifest
metadata, while explicit generation replaces permissions, the complete file hash
map, and the release fingerprint with canonical bytes. Validation/check modes
never write. Merged releases are immutable and corrections use a new SemVer.

Consequence: listing CI must enforce history-based immutability, while local
tooling proves checkout structure and content identity.

## 2026-07-16: Permissions Publish a Fail-Closed Worst-Case Union

Context: per-stage details alone are cumbersome for consumers, but a coarse tier
can hide dangerous access.

Decision: publish deterministic risk, capability, network, filesystem, and
secret sets, while findings attribute each contribution to a stage/reviewer.
Unbounded default/yolo/Bash access is explicit `*`; unknown permission-bearing
constructs block generation.

Consequence: consumers get compact risk disclosure without silently narrowing
future Hive behavior.

## 2026-07-16: Catalog Presence Requires Two Current Review Gates

Context: structural validity alone is not permission to list prompts that may
run with repository write access.

Decision: catalog generation consumes an explicit normalized evidence record
set. Eligibility requires passing lint and affirmative human approval bound to
the same generated release fingerprint and exact review head SHA. Missing or
negative states omit; malformed/stale/contradictory states abort.

Consequence: task 1849 may store evidence however it chooses but must emit or
adapt the normalized reader contract before catalog generation.

## 2026-07-16: Standalone Structure, Optional Hive Compatibility

Context: requiring Hive for every author check would make registry validation
less portable, while silently skipping Hive in CI would weaken compatibility.

Decision: all registry structure/integrity checks use Ruby standard/default
libraries. If installed, Hive's public descriptor parser is an additional check;
local absence warns and explicit `--require-hive` fails.

Consequence: normal author commands remain offline and dependency-light, while
CI can prove the declared Hive minimum without duplicating Hive's full parser.

## 2026-07-17: Catalog Trust and Lifecycle Are Independent Axes

Context: a single tier string cannot distinguish release-time verification,
current trust, execution risk, discoverability, exact-version safety, or public
security advisories. Silently removing non-listed releases would also erase the
audit trail installers need.

Decision: preserve immutable release tier separately from current tier,
permission risk, and the closed `listed`/`soft_hidden`/`yanked`/`revoked`
lifecycle. Retain dual-gated versions and ordered transition/advisory history in
the canonical catalog. Verified history requires digest-bound GitHub Actions
signature/attestation evidence; high-risk listing requires two distinct current
maintainers.

Consequence: discovery/latest use only listed releases, exact soft-hidden and
yanked resolution remains available, and revoked exact resolution fails closed
with mandatory public advisories. No trust signal substitutes for lint or human
approval.

## 2026-07-18: Installation Uses the Catalog Commit, Not the Review Head

Context: designated review evidence binds a pull-request head, but this
repository uses squash merges. A reviewed head is therefore not necessarily an
ancestor of the resulting default-branch catalog and may become unreachable
after branch deletion.

Decision: keep `listing_approval.head_sha` as the immutable review audit
identity, while package installation materializes the exact version directory
from the already-verified catalog commit. Human `package_url` links use the
default branch plus an immutable version path rather than the transient review
head.

Consequence: the installer remains reproducible without depending on retained
pull-request refs, and the two identities are not conflated. History-based CI
must continue rejecting any mutation to an existing version directory.

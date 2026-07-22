# Package and Catalog Contract

`docs/PACKAGE_FORMAT.md` is the public authority. This page records the compact
cross-task contract for agents implementing CI, seeding, site, or installers.

## Package identity

- Releases live at immutable `packages/<name>/<semver>/` paths.
- The exact-base security gate rejects any changed root already present at the
  base revision; fixes must add a wholly new SemVer directory.
- `honeycomb-manifest/v1` is strict and independent from Hive/hive-bench schemas.
- Authors own metadata and safe top-level `x-*`; generation owns normalized
  permissions, exact payload file SHA-256s, and `release_sha256`.
- Only root `manifest.yml` is excluded from payload hashing. Mutable community
  reviews live separately at `reviews/<name>/<version>/<github-user>.md` and
  never enter the package file map or archive identity.
- `source.revision` is upstream provenance, not registry release or reviewed-head
  identity.

## Managed runtime metadata

New packages are agent-agnostic. Every executable stage, reviewer, and reviser
declares a stable `mapping_role`, `mapping_contract` revision, and exact
permission block; embedded `agent`, `model`, and `effort` are rejected. The
manifest permission union remains deterministic disclosure/catalog data, not an
actor execution policy.

The strict `x-hive` extension has required `tools` and `optional_inputs` plus
optional `prompt_assets` and `mapping_recommendations`. Tool paths must be
normalized, manifest-inventoried regular files with Git's trusted executable
bit; undeclared executable payload files fail. Prompt assets are normalized
manifest-inventoried regular files exposed from the pinned package root as
inert context. Optional input names authorize an explicit sorted set of derived
executable slot IDs, never terminal or unknown slots. Secret values are not
package content. Mapping recommendations are sorted unique slot entries with
only optional portable `low`, `medium`, or `high` effort; they name executable
slots only and remain non-binding installation input rather than packaged
agent/model identity.

Historical immutable releases `bench/0.1.0`, `docs-sync/0.1.0`, and
`task-inspect/0.1.0` alone retain the pre-contract parser path. The allowlist is
exact by name and version; new versions use the full managed contract.

## Consumer catalog

`honeycomb-catalog/v2` is a flat name-then-SemVer list. Every dual-gated version
remains present, including soft-hidden, yanked, and revoked releases. Each entry
contains its own version plus the highest dual-gated `listed` `latest_version`
or `null`. The user-facing install string always selects `honeycomb/<name>`;
`HoneycombRegistry::Catalog.resolve` defines the catalog-side exact behavior.

The catalog projects manifest description/author/license/Hive minimum/permission
data, independent trust/lifecycle/review metadata, deterministic package and
review URLs, source SHA, and a compact listing-approval identity. It does not
embed full manifests or timestamps generated at runtime.
Canonical catalog JSON matches Hive's workflow-registry consumer bytes:
objects are recursively key-sorted, keys and string values are NFC-normalized,
the document is compact, and it ends with one line feed. The producer keeps a
fixed byte vector for this boundary; its evidence/approval JSON uses a separate
indented canonical representation.

Catalog `reviews_url` preserves the exact designated-maintainer approval URL.
Nullable `community_reviews_url` is the default-branch external community-review
directory only when records exist. Every designated review also remains in
`listing_approval.reviews` with explicit independent or repository-owner
authority; neither community content nor verdict counts affect eligibility.

V2 adds nullable `community_reviews_url` and explicit approval authority without
changing v1 `reviews_url`.
`schemas/catalog-v1.json` is retained unchanged as the strict historical
contract; current producers emit v2 and consumers branch on the root schema.

The contract carries immutable `release_tier`, mutable `current_tier`,
authoritative `permission_risk`, lifecycle `state`, Verified signature and
attestation evidence, ordered tier/state `history`, and public `advisories` as
independent fields. Discovery/latest use only `listed`. Exact resolution remains
allowed for `soft_hidden` and `yanked`; `revoked` raises with mandatory public
advisories. Historic Verified releases retain verification even after current
demotion to Community.

Independent low/moderate risk needs one current approved maintainer and high
risk needs two distinct current approvals for the same release and exact review
head. A canonical first-party Community release may instead use one protected
repository-owner approval at any risk; any current denial makes the version
ineligible. Verified evidence binds the
canonical immutable archive identity to an exact GitHub Actions keyless signer
and attestation workflow identity.

The designated review `head_sha` is an audit identity, not the installation
source commit: squash merging may make it unreachable from the catalog commit.
Installers materialize `packages/<name>/<version>/` from the verified catalog
commit and validate the manifest/file hashes there. Human `package_url` links
use the default branch plus the immutable version path.

Catalog generation validates all packages before filtering. Therefore a broken
unlisted package aborts output rather than hiding behind missing evidence.
Offline approval export requires prior normalized evidence and preserves
unselected versions plus tier/state/verification/history/advisory projections,
so refreshing lint cannot silently relist or demote a version.
The canonical mutable projection is
`normalized/listing-evidence-v1.json` on the protected
`honeycomb-evidence` branch. Registry-original packages use a documented
two-commit release: a preserved Git source commit followed by the generated
manifest commit. This avoids a manifest/commit hash cycle without changing the
meaning of `source.revision`. Scoped descriptor directories and file rules use
Hive's exact `../../../..` project anchor so manifests can distinguish
`repository/docs/**` from repository-wide write access.

The catalog publication workflow fetches complete registry history. Seed
provenance tests intentionally read the preserved source commit, which may live
on a retained release branch rather than the pull request's first-parent
history; a shallow pull-request checkout cannot prove that content identity.

Bench stage scripts ask Git for the nested `.hive-state` checkout root, verify
that identity, use its containing HiveBench source worktree, then verify
`harness/hive_run.rb` exists before continuing. This avoids fixed
parent-directory traversal, remains independent of Hive's task-directory
depth, and requires no security-lint suppression requests.

## Handoffs

- Task 1849: produce/adapt normalized evidence and invoke validator/catalog
  checks in CI.
- Task 1850: shipped the canonical public contribution, security, trust, and
  community-review policies plus their documentation contract tests.
- Candidate sources: manifest-free work remains under `candidates/`, outside
  the canonical package scanner. Promotion into `packages/` must satisfy the
  complete contribution contract and still requires protected evidence before
  catalog inclusion.
- Async Fix candidate: `candidates/async-fix/` has no version or manifest and
  is invisible to package discovery, manifest-all, validation-all, and catalog
  generation. Tests may copy it into a disposable `0.0.0` registry, generate
  temporary provenance and a medium-effort mapping recommendation, and install
  it through an exact Hive checkout. Those sandbox bytes and passing execution
  evidence do not authorize a package version, canonical manifest, listing,
  site publication, deployment, or Hive workflow removal.
- Root Cause Repair: `packages/root-cause-repair/1.0.0` is an immutable package
  whose canonical manifest binds its registry-original behavior source. Package
  and disposable-registry tests are behavioral evidence; protected listing
  evidence and generated catalog projection separately determine public-install
  status. It is a Git-only high-risk workflow whose install-time mappings cover every
  executable actor and whose arbitrary local command execution may leave
  intended target mutations uncommitted. `verified`, `not-reproduced`, and
  `blocked` are semantic terminal outcomes, not catalog trust or publication
  states.
- Reviewer Panel: `packages/reviewer-panel/1.0.0` is also an immutable package
  whose canonical manifest binds its registry-original behavior source.
  Correctness, security,
  reliability, and test-evidence are fixed semantic lenses; install-time
  execution mappings are separate configuration and do not establish provider
  or human independence. Git-only high-risk actors may run arbitrary local
  commands and leave attributed repairs uncommitted. `ready`,
  `changes-requested`, `inconclusive`, and `state-stale` are analytical states,
  not merge approval, trust endorsement, listing approval, or release status.
  Protected evidence and the generated catalog independently control discovery.
- Static site: consume catalog entries as generated; do not reinterpret package
  manifests independently.
- Hive: consumes the documented install/latest semantics and owns per-slot
  execution mappings plus immutable task configuration pins.

Managed-repair publication uses the ordinary two-commit and protected-evidence
flow: an owner-approved behavior source commit, canonical manifest generation
in a later commit, security lint, required approval, catalog projection, site
publication, public-install acceptance, and live-run evidence. The repository
owner is the sole authority for each remote or release action and for any later
Hive template removal; local passing tests do not replace those gates.

Reviewer Panel's source and manifest commits complete the two-commit package
provenance. The sole owner used the protected repository-owner publication lane
for both managed-repair releases; no agent verdict or local test supplied that
authority. Exact-head lint/approval evidence and generated catalog projection
are complete. Production site publication, clean public install/task-creation
acceptance against released Hive, and deployment verification are also
complete. Provider-backed live-run evidence and any Hive template removal
remain separate gates.

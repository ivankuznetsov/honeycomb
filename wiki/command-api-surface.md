# Command and API Surface

This page tracks shipped registry commands plus the external Hive consumer
surfaces. Full field and safety details live in `docs/PACKAGE_FORMAT.md`.

## Public Terms

- A published Hive workflow package is a **honeycomb**.
- The public catalog is named `hivecli.sh/honeycombs`.
- User-facing surfaces should use "honeycomb" for published workflow packages.

## Hive Install Command

Hive owns the install form:

```sh
hive workflow install honeycomb/<name>
```

Released Hive can install eligible catalog releases. The flagship sources use a
newer contract in which installation maps every executable slot to an agent,
stores an immutable configuration digest beside the package generation, and
pins both identities into created tasks. Those flagships must not declare
public compatibility until that Hive prerequisite is released.

`root-cause-repair/1.0.0` is an immutable package release with a canonical
manifest. `hive workflow install honeycomb/root-cause-repair` resolves it only
when current protected evidence projects it into the generated catalog;
package presence alone is not a public-install claim. Disposable-registry
acceptance also passes explicit high-risk escalation but remains local evidence.

Hive installation asks for agent mappings for all seven semantic slots and
suggests supported defaults, as it does during Hive initialization. The choices
configure execution identity; they do not become part of the workflow or
change the `verified`, `not-reproduced`, and `blocked` outcome contract. All
slots are unbounded, so installation must disclose high-risk arbitrary local
command execution and repository mutation before activation.

`reviewer-panel/1.0.0` has the same package-versus-catalog boundary:
`hive workflow install honeycomb/reviewer-panel` resolves it only when current
protected evidence projects it into the generated catalog. Local acceptance
uses the exact clean pinned Hive revision. That runtime asks for mappings across
basis, council, the four fixed semantic lenses, repair, and readiness; it
rejects mappings whose profile cannot enforce a bounded lens before activation.
The acceptance fixture maps all compatible slots to one profile, proving that
lens semantics do not imply a particular provider, independent providers, or
human collaborators.

Installation must disclose Reviewer Panel's Git-only high-risk arbitrary local
commands and possible uncommitted repair mutations. Its `ready`,
`changes-requested`, `inconclusive`, and `state-stale` values are analytical
outcomes, not merge approval, trust/listing approval, or release authority.

`video-production/0.1.0` is currently a behavior-source candidate in the
canonical package path, not a listed release. Its packaged executable supports
`validate`, `dry-run`, `approval-template`, `capture`, `verify`, and
`publish-ready`. The final command writes local evidence with
`published: false`; none of these operations submits a listing or performs a
remote publication action. The source seed must receive a real source revision
and generated canonical manifest before ordinary package validation can pass.

## Shipped Registry Commands

| Command | Mutating mode | Read-only mode |
|---|---|---|
| `ruby script/honeycomb-manifest` | Explicit canonical manifest generation | `--check` |
| `ruby script/honeycomb-validate` | None | One path or `--all`; `--json`; `--require-hive` |
| `ruby script/honeycomb-catalog --evidence PATH` | Approval-gated root catalog generation | `--check` |
| `ruby script/honeycomb-security-lint` | None | PR metadata, gate state, JSON/Markdown output paths |
| `ruby script/honeycomb-listing-approval issue` | Append immutable trusted evidence | None; protected workflow plumbing |
| `ruby script/honeycomb-listing-approval export` | Write normalized evidence output | Reads an explicit evidence snapshot plus required prior normalized evidence |
| `ruby script/honeycomb-reviews` | None | Validates current-tree or exact-SHA community reviews |

All commands resolve a repository root independently of the caller's current
directory. `--root` supports automation/fixtures. Catalog `--output` is accepted
only when it still resolves to root `catalog.json`.

Exit 0 means success/no error findings, exit 1 means validation or drift errors,
and exit 2 means invocation/internal failure. Warnings and info do not fail.
Validator `--json` always emits a stable array of exact `{path, code, message,
severity}` objects, including exit-2 terminal findings.

Security lint emits `honeycomb.security-lint/v1`. Exit 0 means pass/unchanged,
exit 1 means blocked/awaiting/expired, and exit 2 means invocation or incomplete
analysis. `honeycomb-security-lint-report` is trusted workflow plumbing rather
than an author command; it consumes `GITHUB_EVENT_PATH` and the automatic token
from a default-branch checkout.

`honeycomb-listing-approval issue` likewise consumes only a trusted
`workflow_dispatch` event and the scoped automatic token. `export` performs no
network access and requires one or more explicit immutable lint paths under a
checked-out `honeycomb-evidence` snapshot plus `--previous` normalized evidence.
It retains unselected records and carries durable tier, lifecycle, verification,
history, and advisory decisions forward. `issue` accepts an exact requested
suppression against failing preliminary evidence only under independent
authority when trusted finalization produces a complete passing result. The
repository-owner authority is limited to a canonical first-party pull request,
requires an already-passing result and explicit responsibility acknowledgement,
and rejects every suppression.

Local Hive absence is a warning; `--require-hive` makes absence an error. Strict
mode is explicit and never inferred from environment variables.

## Package Shape

The shipped version layout is:

- `packages/<name>/<semver>/workflow.yml`;
- non-empty `instructions/` and `README.md`;
- generated canonical `manifest.yml` using `honeycomb-manifest/v1`.

## Catalog and API Status

Root `catalog.json` is a shipped deterministic `honeycomb-catalog/v2` artifact.
It carries independent release/current tier, permission risk, lifecycle,
verification, transition history, and advisory fields. Discovery/latest include
only listed entries; exact soft-hidden/yanked versions remain resolvable and
revoked versions fail closed. The catalog currently lists the
`task-inspect/0.1.0` production canary. Package source directories that lack
eligible protected evidence do not appear in discovery, even when their
behavior tests pass.
`hivecli.sh/honeycombs` remains a documented external static rendering surface;
no route, handler, or site code is implemented here.

Root Cause Repair's owner-authorized source and manifest commits are complete.
No local command can implicitly issue protected lint or approval evidence,
mutate the catalog, publish the static site, certify a public install or live
workflow run, or remove a corresponding Hive-shipped workflow. The catalog,
site, deployment, and clean public install/task-creation gates are now recorded
as complete; provider-backed live execution and template removal remain
separately recorded owner-controlled gates.

Candidate sources live outside `packages/`, so package-wide validation and
catalog commands do not silently treat a manifest-free candidate as a release
submission. Promotion into the canonical package tree is an explicit reviewed
change, not an effect of testing or opening a source-candidate pull request.

Reviewer Panel follows the same explicit release boundary. Its source and
manifest commits are complete, while disposable-registry tests cannot issue
protected evidence, mutate the catalog/site, certify public-install acceptance,
deploy, or remove a Hive template. The sole owner may use the protected
repository-owner publication lane, but agent output never qualifies as that
decision. Protected evidence, catalog/site publication, production deployment,
and clean public install/task-creation acceptance are now complete;
provider-backed live execution and template removal are not.

`.github/workflows/catalog-check.yml` is the read-only publication gate. It
compares the committed catalog with
`honeycomb-evidence:normalized/listing-evidence-v1.json` on pull requests,
default-branch pushes, and manual reruns. Publication remains an ordinary
reviewed catalog commit followed by a validated `hive-site` snapshot commit.

Catalog `reviews_url` remains the exact designated-maintainer approval URL.
Nullable `community_reviews_url` names the default-branch community-review
directory only when at least one validated record exists.
The strict v1 schema remains checked in unchanged; v2 is an explicit versioned
extension rather than a new required property smuggled into v1.

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
suppression against failing preliminary evidence only when trusted finalization
produces a complete passing result; ordinary affirmative approvals require an
already-passing result.

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

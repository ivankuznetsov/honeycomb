# Honeycomb Package Format v1

This document is the authoritative contract for publishable honeycombs in this
repository. The implementation is offline Ruby standard/default-library code;
all three commands share the same schema, permission, integrity, evidence, and
serialization logic.

## Version directory

Each release is stored directly at `packages/<name>/<semver>/`:

```text
packages/example/1.0.0/
  workflow.yml
  README.md
  manifest.yml
  instructions/
    build.md
```

`workflow.yml`, `README.md`, `manifest.yml`, and at least one regular file below
`instructions/` are required. Nested regular files and dotfiles are allowed and
hashed. Symlinks, FIFOs/devices/sockets, unreadable files, backslash path
ambiguity, absolute paths, `.`/`..` traversal, and names that collide after
Unicode NFC normalization are rejected before hashing.

An instruction reference must be a normalized relative path below the same
version's `instructions/` directory and resolve to a regular package file.
Merged version directories are immutable. Fixes publish a new SemVer version;
checkout validation does not inspect Git history, so listing CI owns enforcement
against the merge base.

Mutable community reviews are deliberately outside this directory at
`reviews/<name>/<version>/<github-user>.md`. They are not manifest payload,
signed archive content, security-lint evidence, or designated listing approval.
Adding or moderating a review cannot change the immutable release fingerprint.
The canonical public review format and moderation policy are in [community
reviews](REVIEWS.md).

Names match `\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z` (3–64 characters).
Versions are strict SemVer 2.0 strings and directory spelling must equal the
manifest value. Build metadata does not affect precedence; two eligible versions
with equal precedence but different build metadata are rejected because there
is no unique latest version.

## Manifest lifecycle

Authors seed `manifest.yml` with metadata, then explicitly generate the complete
canonical document:

```sh
ruby script/honeycomb-manifest packages/example/1.0.0
ruby script/honeycomb-manifest --check packages/example/1.0.0
```

Generation preserves valid author fields and top-level `x-*` extensions. It
replaces only `permissions`, `files`, and `release_sha256`. Generation writes by
same-directory temporary file, flushes it, and atomically renames it only after
all validation succeeds. `--check` regenerates in memory and never writes.

The executable input fixture is
[`test/fixtures/packages/valid/example/1.0.0/`](../test/fixtures/packages/valid/example/1.0.0/),
and its exact generated output is
[`test/fixtures/expected/manifest.yml`](../test/fixtures/expected/manifest.yml).

### `honeycomb-manifest/v1` fields

| Field | Owner | Contract |
|---|---|---|
| `schema` | Author | Exactly `honeycomb-manifest/v1`. |
| `name` | Author | Lowercase registry name matching the version directory. |
| `version` | Author | Strict SemVer matching the version directory spelling. |
| `description` | Author | Non-empty text. |
| `author` | Author | Exactly `{name, url?}`; URL is safe absolute HTTP(S). |
| `license` | Author | One identifier from `policy/spdx-license-ids.txt`; expressions are not accepted in v1. |
| `hive_min_version` | Author | Strict SemVer used by explicit Hive compatibility checks. |
| `source` | Author | Exactly `{url, revision}`; revision is lowercase 40- or 64-character commit hex. |
| `permissions` | Generator | Exact normalized worst-case permission union described below. |
| `files` | Generator | Sorted repository-relative path to lowercase SHA-256 mapping for every regular package file except root `manifest.yml`. |
| `release_sha256` | Generator | SHA-256 of canonical manifest YAML with this self-referential field omitted. |
| `x-*` | Author | Optional top-level lowercase extensions containing only JSON-like primitive values. |

Unknown core top-level keys are rejected unless they match safe `x-*` syntax.
All known nested objects reject unknown keys. YAML input must be one UTF-8,
JSON-like document with string mapping keys; duplicate keys, aliases, merge
aliases, custom tags, non-finite numbers, timestamps/custom objects, and multiple
documents fail before projection.

Canonical YAML uses the core field order above, lexicographically sorted file
and extension keys, UTF-8, LF newlines, one final newline, JSON-quoted strings,
and deterministic collection indentation. It does not use Psych's emitter.

### Three distinct identities

- `source.revision` identifies the upstream source/provenance selected by the
  author and becomes catalog `source_sha`.
- `release_sha256` identifies the canonical metadata, derived permissions, and
  exact package file hashes.
- Evidence `head_sha` identifies the exact registry Git head reviewed by both
  lint and the human approver.

These values are deliberately not interchangeable. Catalog inclusion requires
current evidence for the release fingerprint and agreement on the review head.

### Registry-original source commits

An original honeycomb authored directly in this registry still uses a Git
commit for `source.revision`; the 64-character form does not authorize a
payload digest. Avoid a self-referential manifest/commit cycle with a
two-commit release: first commit the behavior-bearing source, then generate the
final manifest in a later commit that cites the first commit. The source commit
must remain reachable from the default branch, so merge the release pull
request with a merge commit rather than squash or rebase. Point `source.url` at
the exact source commit and record the behavior-bearing paths:

```yaml
x-provenance:
  kind: registry-original
  source_paths:
    - workflow.yml
    - instructions/example.md
```

The source commit may contain an incomplete or stale generated manifest; the
later release commit is the authority for generated fields and must pass full
validation. Every listed `source_path` in the final package must be byte-equal
to that path at `source.revision`. A changed behavior source therefore requires
a new source commit and package version. This preserves the existing commit-ID
schema while making provenance independently inspectable.

## Permission projection

The generator visits active stages, council reviewers, and council revise
agents. Every contributing field produces an attributed finding. The manifest
stores the compact union:

```yaml
permissions:
  risk: "low"
  capabilities:
    - "filesystem-read"
  network_hosts: []
  filesystem_read:
    - "repository"
    - "task"
  filesystem_write: []
  secrets: []
```

The six keys are exact. Arrays are sorted unique sets. `*` is reserved for
unbounded access and, when present, is the only array value.

| Hive descriptor request | Projection |
|---|---|
| `read-only` | Repository/task read, `filesystem-read`, low risk. |
| `scoped` + bare `Read`, `LS`, `Grep`, `Glob` | Task plus declared read scopes, low risk. |
| `scoped` + bare `Write`, `Edit`, `MultiEdit`, `NotebookEdit` | Task plus declared write scopes, moderate risk. |
| `Read(path)` / `Edit(path)` | Only the normalized task/project path for that capability. |
| `scoped` + `WebFetch`, `WebSearch` | Unbounded host `*`, network capability, high risk. |
| Missing permissions, `yolo`, or Bash (including the Bash tool) | All four capabilities and `*` hosts/read/write/secrets, high risk. |

Safe ordinary `dirs` entries are projected as `task/<relative-path>`. Hive
workflow tasks have a stable four-level anchor from the task folder to the
project root, so exact `../../../..` projects as `repository` and
`../../../../<normalized-path>` projects as `repository/<normalized-path>`.
No other `..` traversal is accepted. A bare file tool uses `task` plus its
declared `dirs`; a qualified `Read(path)` or `Edit(path)` contributes only that
normalized path. `Write(path)`, `MultiEdit(path)`, `NotebookEdit(path)`,
`LS(path)`, `Grep(path)`, and `Glob(path)` fail because Hive does not enforce
those forms; use `Edit(path)` or `Read(path)`. Absolute, home-relative, Windows
drive, backslash, empty, null-containing, ambiguous, or escaping paths fail.
Unknown presets, keys, tools, blank blocks, or future permission-bearing
constructs fail closed rather than publishing a narrower summary.

## Read-only validation and Hive compatibility

Validate one version or all discovered versions:

```sh
ruby script/honeycomb-validate packages/example/1.0.0
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-validate --all --json --require-hive
```

Validation checks package location and required content, strict manifest schema,
directory identity, instruction references, exact file set and hashes,
re-derived permissions, release fingerprint, canonical bytes, and filesystem
safety without writing.

When the local Hive library is installed, the validator additionally calls
`Hive::Workflows::DescriptorParser.parse_hash` with a synthetic
`<package-name>.yml` path in the version directory. This satisfies Hive's
filename/ID rule while preserving relative instruction resolution. The
installed Hive version must meet `hive_min_version`; parser rejection or an old
runtime is an error. Absence is a non-failing warning locally. CI opts into
`--require-hive`, where absence is an error. No ambient CI variable changes the
mode.

Human findings are the default. `--json` emits a stable array whose objects have
exactly `path`, `code`, `message`, and `severity`, in deterministic order.
Informational and warning findings do not fail a command.

## Listing evidence

`honeycomb-catalog` requires an explicit normalized JSON record set. This is an
input boundary for listing CI; `schemas/listing-evidence-v1.json` describes the
public shape:

```json
{
  "schema": "honeycomb-listing-evidence/v1",
  "records": [
    {
      "name": "example",
      "version": "1.0.0",
      "release_tier": "community",
      "current_tier": "community",
      "permission_risk": "low",
      "state": "listed",
      "lint": {
        "status": "pass",
        "release_sha256": "<64 lowercase hex>",
        "head_sha": "<40 or 64 lowercase hex>",
        "checked_at": "2026-07-16T10:00:00Z"
      },
      "approvals": [
        {
          "status": "approved",
          "release_sha256": "<same release>",
          "head_sha": "<same head>",
          "reviewer": "registry-reviewer",
          "reviewed_at": "2026-07-16T11:00:00Z",
          "review_url": "https://example.test/reviews/example-1.0.0",
          "evidence_digest": "<64 lowercase hex>"
        }
      ],
      "verification": null,
      "history": [],
      "advisories": []
    }
  ]
}
```

Root, record, lint, approval, verification, history, and advisory keys are
strict; JSON duplicate keys and non-canonical record/reviewer/history/advisory
ordering are rejected. Lint statuses are `pass`, `pending`, and `fail`.
Approvals are current designated-maintainer decisions (`approved` or `denied`);
an empty array represents no approval. Every decision binds the exact release,
head, reviewed evidence digest, reviewer, timestamp, and pull-request
`review_url`. Catalog `reviews_url` preserves the first exact designated
maintainer audit URL; the separate nullable `community_reviews_url` discovers
the external community-review namespace. A low or moderate risk honeycomb needs
one distinct current approval. `risk: high` needs two; any current denial leaves
it ineligible.

Trust and lifecycle are independent:

- `release_tier` is the immutable tier at release; `current_tier` is the current
  `community` or `verified` classification.
- `permission_risk` must equal the generated manifest and never derives from a
  tier or lifecycle state.
- `state` is exactly `listed`, `soft_hidden`, `yanked`, or `revoked`.
- `history` starts from the release tier and `listed`, records exact ordered
  tier/state transitions with actor, reason, time, and URL, and must project the
  declared current values. This prevents silent demotion or relisting.
- `advisories` are independently ordered public records. Revocation requires at
  least one advisory.

A current or historic Verified tier requires `verification`. The immutable
archive identity is SHA-256 over the canonical release fingerprint plus the
manifest's complete sorted payload file map. The record also carries an exact
GitHub Actions keyless signature identity, the GitHub OIDC issuer, signature
reference, matching Actions attestation repository/workflow identity and
reference, and an RFC 3339 verification time. Community-only releases may use
`null`. Digest, workflow, signer, URL, and timestamp mismatches fail closed.

Missing records, pending/failed lint, insufficient approvals, or a denial omit
the version without failing catalog generation. Malformed/duplicate records,
unknown package identities, stale release fingerprints, or lint/approval head
or release disagreement, permission-risk drift, invalid verification, broken
history, or missing revocation advisories abort the entire build without
replacing `catalog.json`.

## `honeycomb-catalog/v2`

The root document is:

```json
{
  "schema": "honeycomb-catalog/v2",
  "entries": []
}
```

Each dual-gated version remains in the canonical catalog, including
soft-hidden, yanked, and revoked history. `schemas/catalog-v2.json` describes the
output. Entries carry these projections:

| Field | Source |
|---|---|
| `name`, `version`, `description`, `author`, `license`, `hive_min_version`, `permissions` | Validated manifest. |
| `latest_version` | Highest dual-gated `listed` SemVer for the same name, or `null`. |
| `release_tier`, `current_tier`, `permission_risk`, `state` | Independent listing evidence fields. |
| `discoverable`, `exact_resolution` | Derived lifecycle behavior. |
| `verification`, `history`, `advisories` | Strict listing evidence copied without reinterpretation. |
| `install_command` | Fixed `hive workflow install honeycomb/<name>`. |
| `package_url` | Fixed registry repository URL at the evidence head SHA and exact version path. |
| `reviews_url` | Exact designated-maintainer pull-request approval URL retained for v1 compatibility. |
| `community_reviews_url` | External `reviews/<name>/<version>/` namespace on the default branch, or `null` when no review exists. |
| `source_sha` | Manifest `source.revision`. |
| `listing_approval` | Release/head/lint identity plus every qualifying reviewer audit record. |

Entries sort by name then SemVer. Discovery and implicit latest selection use
only `listed` entries. Exact resolution remains allowed for `soft_hidden` and
`yanked`; a `revoked` exact version raises a fail-closed result carrying its
public advisories. The catalog contains no full manifest, package file map,
generation timestamp, or caller-supplied shell projection.

`listing_approval.reviews[*].review_url` retains every immutable designated
maintainer pull-request review, while catalog `reviews_url` preserves the first
such URL. `community_reviews_url` is the optional mutable external review
directory. Community review content and verdict counts never participate in
catalog eligibility.

Version 2 adds only `community_reviews_url`; it does not repurpose the v1
`reviews_url` approval-audit field. The strict historical
`schemas/catalog-v1.json` remains unchanged for consumers that explicitly
support v1. Producers emit v2, and consumers must select behavior from the exact
root `schema` instead of accepting unknown fields under a v1 parser.

```sh
ruby script/honeycomb-catalog --evidence path/to/evidence.json
ruby script/honeycomb-catalog --check --evidence path/to/evidence.json
```

Generation validates every candidate package before evidence filtering and
atomically replaces root `catalog.json` only on total success. `--check` compares
in memory and never writes. `--root` is available to repository automation and
tests; catalog `--output`, when supplied, must still resolve to that root's
`catalog.json`.

## Command terminal states

| Command | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|
| `honeycomb-manifest` | Generated/current | Derivation, safety, schema, or drift error | Invocation/internal failure |
| `honeycomb-validate` | No error findings | One or more validation errors | Invocation/internal failure |
| `honeycomb-catalog` | Generated/current | Package, evidence, SemVer, or drift error | Invocation/internal failure |
| `honeycomb-reviews` | All community reviews valid | Record, identity, binding, or invocation error | Not used |

In validator JSON mode, invocation/internal failure still emits a valid
four-key finding array on stdout and places the diagnostic on stderr.

## Offline verification

No command fetches schemas, licenses, packages, or evidence. The complete local
contract is:

```sh
ruby test/run.rb
ruby script/honeycomb-manifest --check --all
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-validate --all --json --require-hive
ruby script/honeycomb-catalog --check \
  --evidence test/fixtures/listing-evidence/empty.json
ruby script/honeycomb-reviews
```

The strict Hive command succeeds only when a compatible Hive runtime is locally
installed. The remaining commands use Ruby standard/default libraries and
checked-in policy/fixtures only.

## Design references

The v1 manifest is independent rather than a copy of either upstream format.
Compatibility and permission mappings were designed against pinned sources:

- Hive commit `c727386124dd549db577431829372b811cc05dc8`:
  [workflow documentation](https://github.com/ivankuznetsov/hive/blob/c727386124dd549db577431829372b811cc05dc8/docs/workflows.md),
  [descriptor parser](https://github.com/ivankuznetsov/hive/blob/c727386124dd549db577431829372b811cc05dc8/lib/hive/workflows/descriptor_parser.rb),
  [permission documentation](https://github.com/ivankuznetsov/hive/blob/c727386124dd549db577431829372b811cc05dc8/docs/permissions.md), and
  [permission implementation](https://github.com/ivankuznetsov/hive/blob/c727386124dd549db577431829372b811cc05dc8/lib/hive/permission_scope.rb).
- hive-bench commit `a63d66520daa8b0dfd7966932241a24b99eeb959`:
  [corpus schema](https://github.com/ivankuznetsov/hive-bench/blob/a63d66520daa8b0dfd7966932241a24b99eeb959/corpus/SCHEMA.md) and
  [manifest example](https://github.com/ivankuznetsov/hive-bench/blob/a63d66520daa8b0dfd7966932241a24b99eeb959/corpus/add-i-key-with-legend-260522-ca28/manifest.yml).

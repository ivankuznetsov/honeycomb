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
| `scoped` + `Read`, `LS`, `Grep`, `Glob` | Bounded read scopes, low risk. |
| `scoped` + `Write`, `Edit`, `MultiEdit`, `NotebookEdit` | Bounded write scopes, moderate risk. |
| `scoped` + `WebFetch`, `WebSearch` | Unbounded host `*`, network capability, high risk. |
| Missing permissions, `yolo`, or Bash (including the Bash tool) | All four capabilities and `*` hosts/read/write/secrets, high risk. |

Safe `dirs` entries are projected as `task/<relative-path>` and supplement the
repository/task scopes for the requested file capabilities. Absolute,
backslash, empty, null-containing, or traversing directories fail. Unknown
presets, keys, tools, blank blocks, or future permission-bearing constructs fail
closed rather than publishing a narrower summary.

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
input boundary for listing CI, not task 1849's prescribed persistence format:

```json
{
  "schema": "honeycomb-listing-evidence/v1",
  "records": [
    {
      "name": "example",
      "version": "1.0.0",
      "tier": "reviewed",
      "lint": {
        "status": "pass",
        "release_sha256": "<64 lowercase hex>",
        "head_sha": "<40 or 64 lowercase hex>",
        "checked_at": "2026-07-16T10:00:00Z"
      },
      "approval": {
        "status": "approved",
        "release_sha256": "<same release>",
        "head_sha": "<same head>",
        "reviewer": "registry-reviewer",
        "reviewed_at": "2026-07-16T11:00:00Z",
        "review_url": "https://example.test/reviews/example-1.0.0"
      }
    }
  ]
}
```

Root, record, lint, and approval keys are strict; JSON duplicate keys are
rejected. Lint statuses are `pass`, `pending`, and `fail`; approval statuses are
`approved`, `pending`, and `denied`. Pending verdicts may contain only their
status. Non-pending verdicts require their identity/audit fields and RFC 3339
timestamps. A version is eligible only for `pass` plus `approved` bound to its
current release and the same head SHA.

Missing records, a missing verdict, pending, failed lint, or denied approval omit
the version without failing catalog generation. Malformed/duplicate records,
unknown package identities, stale release fingerprints, or lint/approval head
or release disagreement abort the entire build without replacing `catalog.json`.

## `honeycomb-catalog/v1`

The root document is:

```json
{
  "schema": "honeycomb-catalog/v1",
  "entries": []
}
```

Each eligible version gets a flat entry with these exact projections:

| Field | Source |
|---|---|
| `name`, `version`, `description`, `author`, `license`, `hive_min_version`, `permissions` | Validated manifest. |
| `latest_version` | Highest eligible SemVer for the same name. |
| `tier` | Listing evidence. |
| `install_command` | Fixed `hive workflow install honeycomb/<name>`. |
| `package_url` | Fixed registry repository URL at the evidence head SHA and exact version path. |
| `reviews_url` | Approved evidence review URL. |
| `source_sha` | Manifest `source.revision`. |
| `listing_approval` | Release SHA, head SHA, lint time, approver, and approval time. |

Entries sort by name then SemVer and every version carries the same eligible
`latest_version` for its name. The catalog contains no full manifest, package
file map, generation timestamp, or caller-supplied shell/URL projection.

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

# Security Lint CI

Honeycomb submissions use two GitHub Actions workflows so fork content never
runs with a write token or repository secrets.

## Trust boundary

`.github/workflows/security-lint.yml` runs on `pull_request` with only
`contents: read`. Opened, synchronized, and reopened pull requests check out the
trusted base and emit gate-only evidence without reading submitted content. A
`labeled` event checks out the exact fork head only when a maintainer has just
applied `safe-to-validate`. The analyzer invokes the production validator and
the deterministic Ruby scanners; it never executes submitted commands,
instructions, hooks, or network requests.

`.github/workflows/security-lint-report.yml` runs later on `workflow_run`. It
checks out only the default branch and has the narrow metadata permissions
needed to read the artifact, update the pull request, remove the expired label,
and create a commit status. The reporter downloads the artifact itself, verifies
its GitHub SHA-256, parses a bounded single-file ZIP without extracting it,
strict-loads the evidence schema, verifies the evidence content digest, and
binds the result to the current pull-request head before every write.

The authoritative required context is `honeycomb/security-lint`. The analyzer
workflow conclusion is diagnostic because a pull request can propose changes to
its own unprivileged analyzer.

## Gate lifecycle

| Pull-request state | Authoritative status | Required action |
|---|---|---|
| Opened | `pending` | A maintainer inspects the diff and applies `safe-to-validate`. |
| Fresh `safe-to-validate` label, clean evidence | `success` | Human approval remains independently required for catalog eligibility. |
| Fresh label, blocking evidence | `failure` | Resolve the evidence or obtain an exact approved suppression. |
| Synchronize or reopen | `pending` | Prior evidence expires, the label is removed, and a maintainer must reapply it. |
| Missing, malformed, stale, oversized, or mismatched artifact | `error` | Inspect/re-run CI; the reporter does not render attacker-controlled fields. |

Unrelated labels produce an `unchanged` artifact and do not overwrite the
current status or sticky comment. Concurrency cancellation plus current-head API
checks prevent an older run from winning after a new push.

## Evidence contract

`schemas/security-lint-evidence-v1.json` defines
`honeycomb.security-lint/v1`. Every artifact contains:

- the event/gate action, pull-request number, base/head SHAs, workflow run ID,
  attempt, repository, and a self-verifying content digest;
- each changed honeycomb's name, version path, generated `release_sha256`,
  validator findings, authoritative requested permissions, and scanned-file
  accounting;
- redacted extracted commands, observed network hosts, static deny findings,
  secret/PII findings, suppression dispositions, counts, and terminal verdict.

The sticky comment and job summary render the same already-redacted model. Human
sections are capped with explicit omission counts; the bounded JSON artifact is
the machine-readable record. Raw detected secrets and high-confidence personal
identifiers never enter the serializable model.

## Protected tooling

The reporter refuses a passing status when the same pull request changes a
honeycomb and any trusted assessment surface:

- `.github/workflows/`;
- `lib/honeycomb_security_lint.rb` or `lib/honeycomb_security_lint/`;
- `lib/honeycomb_registry.rb` or `lib/honeycomb_registry/`;
- the `honeycomb-*` validator, manifest, catalog, analyzer, or reporter scripts;
- `policy/security-lint.yml` or any checked-in security/catalog schema.

Land those changes in a separate pull request before using them to assess a
honeycomb submission.

## Suppressions and human approval

A manifest `x-security.suppressions` entry is only a request containing one
exact finding fingerprint and a reason. It does not hide or downgrade a
finding. `schemas/listing-approval-v1.json` binds the reviewer decision to the
same honeycomb name/version/path, `release_sha256`, exact head SHA, and reviewed
evidence digest. An approved suppression must name the exact requested
fingerprint; the final evidence retains its original hard severity, request,
approval reference, and downgraded disposition.

`HoneycombSecurityLint::ListingEvidenceAdapter` converts a validated lint record
plus validated approval records into task 1848's strict
`honeycomb-listing-evidence/v1` reader shape. It reconstructs and verifies the
pre-approval digest for downgraded findings. Catalog eligibility still requires
both a passing lint verdict and affirmative human approval for the same release
and head.

The trusted `.github/workflows/listing-approval.yml` workflow issues those
records from a protected `honeycomb-listing-approval` environment. It runs only
default-branch code and verifies the dispatching maintainer's repository
permission, current pull-request review, exact open head, authoritative lint
status, protected-path split, artifact digest, and honeycomb release identity.
Authors cannot approve their own submissions.

The issuer appends the validated lint artifact and a singleton approval record
to the dedicated `honeycomb-evidence` branch through the GitHub Contents API.
Paths are derived only from validated identities:

```text
lint/<head_sha>/<evidence_digest>.json
approvals/<name>/<version>/<head_sha>/<reviewer>.json
```

Existing bytes may be replayed idempotently, but a conflicting record is never
overwritten. The branch is independent of the reviewed pull-request head, so
recording an approval does not create a new SHA that invalidates itself. The
honeycomb pull-request workflow never receives evidence-branch write authority.

For an offline catalog build, check out the evidence branch and explicitly
select the immutable lint records to export. Explicit selection prevents older
append-only heads from becoming current implicitly:

```sh
ruby script/honeycomb-listing-approval export \
  --snapshot /path/to/honeycomb-evidence \
  --lint lint/<head_sha>/<evidence_digest>.json \
  --checked-at 2026-07-17T09:00:00Z \
  --release-tier community \
  --output /path/to/listing-evidence.json
```

The exporter rejects records outside the snapshot, symlinks, oversized or
non-canonical records, duplicate honeycomb versions, stale identities, and
orphaned suppressions before emitting `honeycomb-listing-evidence/v1`.
Its default projection is a listed Community release. The normalized evidence
schema separately supports release/current tier, lifecycle history, verification,
and public advisories; high-risk releases retain both distinct maintainer
approvals. Trust/lifecycle policy changes remain explicit normalized evidence,
never an inference from lint or a honeycomb-controlled field.

## Repository setup and rollout

Repository administrators must:

1. create the `safe-to-validate` label;
2. require the commit status `honeycomb/security-lint` in branch protection;
3. retain fork defaults that withhold repository secrets and write tokens from
   `pull_request` workflows;
4. keep Actions permissions restricted so only the trusted reporter receives
   the permissions declared in its workflow;
5. merge both workflows to the default branch before relying on
   `workflow_run` reporting;
6. create and protect the `honeycomb-listing-approval` environment with the
   required maintainer reviewers;
7. create/protect the `honeycomb-evidence` branch so ordinary pull requests
   cannot update it and only the trusted approval workflow may append records.

After default-branch installation, run a fork canary: confirm the analyzer sees
no custom secret and cannot comment or set status; apply the gate and confirm the
reporter alone updates one sticky comment and the SHA-bound status; then push a
new commit and confirm the status returns to pending, the label is removed, and
the prior run cannot overwrite the new head.

## Local verification

```sh
ruby test/run.rb
ruby script/honeycomb-security-lint --help
ruby script/honeycomb-security-lint-report --help
ruby script/honeycomb-listing-approval --help
```

Focused acceptance coverage lives under `test/security_lint/`, including the
real validator, hostile artifact parser, workflow contracts, reporter races, and
the black-box catalog dual gate. A direct analyzer invocation requires the PR
base/head SHAs and workflow metadata shown by `--help`; use only test data or an
actual pull-request checkout.

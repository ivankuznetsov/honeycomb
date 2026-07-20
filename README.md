# honeycomb

A library of **honeycombs** — publishable workflows for
[hive](https://github.com/ivankuznetsov/hive). Publish yours, install others',
every listing security-reviewed. A honeycomb's stage instructions are agent
prompts that may request powerful repository, network, or tool access, so the
review gate is the product.

- Catalog: **hivecli.sh/honeycombs**
- Install a listed release: `hive workflow install honeycomb/<name>`
- A *honeycomb* = descriptor (`workflow.yml`) + stage instructions + manifest
  (version, author, permissions summary, sha256 integrity)

The repository now ships the independent `honeycomb-manifest/v1` package
contract, offline Ruby tooling for manifest generation and validation, an
approval-gated catalog generator, and fork-safe security-lint CI. The root
catalog contains the listed `task-inspect` production canary. Its contract keeps
Community/Verified history, permission risk, lifecycle state, verification, and
public advisories independent; only listed versions participate in discovery.
Strict community-review validation runs as trusted base code and binds review
identity to the canonical package and catalog without executing submitted code.

The repository also contains the behavior sources for three flagship 1.0.1
packages:

- `architecture` — repository research, proposal, council review, revision,
  and an implementation-ready architecture record;
- `writing` — journalist research and an adversarial writer/editor loop with
  honest ungrounded and round-cap outcomes;
- `seo-content` — research, intent, outline, draft, fact-check, humanization,
  and optimization, including an immutable package-local analyzer.

Package presence is not catalog listing. The three immutable manifests require
the released Hive 0.6.0 runtime; until each package has protected lint evidence
plus the required independent approvals, it is not discoverable or publicly
installable from `honeycomb/<name>`.

## Local managed-repair candidates

`packages/root-cause-repair/1.0.0` is an unpublished, unlisted local source
candidate. It has no canonical `manifest.yml`, protected listing evidence,
catalog entry, or public install path. The checked-in source is for local
contract and exact-pinned Hive acceptance testing only.

This is a full Git-only repair workflow, not a read-only report. Every
executable stage is high-risk and may run arbitrary local commands and leave
intended repository mutations uncommitted. Hive asks for install-time agent
mappings for reproduction, diagnosis, repair, council verification, causal
review, revision, and certification; mapping every slot to one supported agent
does not change the workflow semantics. Terminal certificates use exactly
`verified`, `not-reproduced`, or `blocked`.

The repository owner remains the sole authority for commits, pushes, pull
requests, merges, tags, releases, publication, catalog listing, deployment, and
any later removal of a Hive-shipped workflow. A future release tail requires an
explicit owner request: preserve the behavior source commit, generate and
review the canonical manifest in a later commit, obtain protected lint and
approval evidence, update the catalog and site, and record public-install and
live-run acceptance. Local green tests do not authorize any of those steps.

`packages/reviewer-panel/1.0.0` is likewise an unpublished, unlisted local
source candidate with no canonical manifest, protected evidence, catalog entry,
or public install. Its four fixed semantic lenses are correctness, security,
reliability, and test-evidence. Those meanings belong to the workflow; the
compatible agents or execution profiles chosen during Hive installation do not.
The exact pinned-runtime acceptance maps every slot to one compatible profile,
which demonstrates that the package does not intrinsically require multiple
providers or a particular provider.

Reviewer Panel is Git-only and high-risk. Its basis, test-evidence, repair, and
readiness actors may run arbitrary local commands, and accepted repairs remain
as uncommitted target mutations. `ready`, `changes-requested`, `inconclusive`,
and `state-stale` are state-bound analytical outcomes. They are not human
collaboration, merge approval, trust endorsement, listing approval, release
authorization, publication, or deployment decisions.

The sole owner may later use the protected repository-owner publication lane,
but agent output never satisfies that authority. An explicit owner request is
still required before the source/manifest commits, protected evidence, catalog,
site, public-install, live-run, or Hive-template-removal release tail begins.

```sh
ruby script/honeycomb-manifest --check --all
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-catalog --check \
  --evidence test/fixtures/listing-evidence/empty.json
ruby script/honeycomb-security-lint --help
ruby script/honeycomb-listing-approval --help
ruby script/honeycomb-reviews
ruby test/run.rb

# Focused source-to-Hive acceptance against a compatible checkout
HONEYCOMB_HIVE_SOURCE=/path/to/hive \
  RUBYLIB=/path/to/hive/lib \
  ruby -Itest test/flagship_hive_execution_test.rb
```

See [the package format](docs/PACKAGE_FORMAT.md) for the complete layout,
schemas, integrity model, evidence boundary, permission projection, and command
exit contract. See [Security Lint CI](docs/SECURITY_LINT_CI.md) for the
maintainer gate, analyzer/reporter trust split, required repository settings,
and SHA-bound review evidence. Hive owns install-time agent mappings, immutable
configuration pins, and package runtime context; this repository owns the
reviewed package bytes and catalog eligibility.

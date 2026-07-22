# Dependencies

The registry implementation is deliberately offline and dependency-light.

## Runtime

- Ruby standard/default libraries: Psych/YAML, JSON, Digest, OptionParser,
  Pathname, Set, Tempfile, Time, URI, Zlib, and filesystem APIs.
- Checked-in `policy/spdx-license-ids.txt`; validation never consults a host or
  online license service.
- Hive is an optional local compatibility dependency. When available, the
  validator loads `hive` and `hive/workflows/descriptor_parser`; ordinary
  absence warns, while `--require-hive` requires it and enforces the manifest's
  SemVer minimum.
- No Gemfile, Bundler runtime, application framework, database, network fetch,
  schema registry, or hidden cache is used.

Package tools follow the same explicit standard-library rule. In particular,
SEO provider metrics loads `time` directly before using ISO 8601 timestamps so
behavior is identical across supported Ruby default-library loading modes.

Video Production's package tool uses only Ruby standard/default libraries. Its
trusted-owner capture additionally requires host `docker`, `asciinema`, `agg`,
`ffmpeg`, and `ffprobe`, an already-present digest-pinned image, and a declared
pre-hardened snapshot. The package does not fetch, install, prepare, or mutate
those prerequisites. Three optional credential bindings are authorized only for
the capture slot and remain runtime-only.

The unprivileged analyzer and evidence snapshot exporter remain offline. The
trusted `workflow_run` reporter and protected approval issuer share one isolated
standard-library `Net::HTTP` adapter for GitHub metadata, artifact, Git ref, and
Contents APIs; authorization is never forwarded across artifact redirects.

## Development and CI

`ruby test/run.rb` uses Minitest from Ruby's default library plus stdlib helpers.
The compatible-parser unit seam is injectable, so missing/old/rejecting Hive
states are tested without downloading runtimes. A CI job that invokes
`--require-hive` must install the pinned supported Hive version separately.

GitHub workflows use hosted ephemeral runners and pin `actions/checkout` and
`actions/upload-artifact` to full commit SHAs. There is no dependency cache,
self-hosted runner, artifact extraction action, or gem installation.

The read-only catalog publication gate checks out Hive at the exact compatible
commit recorded in the workflow. The current pin is
`3f91a71bdb29fd641eca9c3dd38d2ddb7a1f1bb6`, the merged Hive source containing
the full managed-workflow runtime contract, production catalog-v2 client, and
non-binding mapping recommendation contract. The gate identifies that exact
clean checkout through
`HONEYCOMB_HIVE_SOURCE`, exposes its libraries through `RUBYLIB`, and runs the
complete registry test suite. Only then does it compare root
`catalog.json` with the normalized snapshot from the protected
`honeycomb-evidence` branch. It receives no secret or write permission and does
not publish any checkout.

The unprivileged security analyzer uses the same exact Hive compatibility commit for
production descriptor validation on maintainer-authorized package heads. It is
checked out separately from submitted content, exposed only through `RUBYLIB`,
and never receives credentials or write permission.

The approval workflow additionally depends on a protected
`honeycomb-listing-approval` environment and an append-only
`honeycomb-evidence` branch. Those GitHub repository settings are rollout
configuration, not runtime package dependencies.

## Services

- `hivecli.sh/honeycombs` is the documented catalog surface.
- GitHub URLs in generated catalog entries use immutable version paths on the
  default branch; catalog generation never calls GitHub. Installers use their
  verified catalog commit rather than trusting the presentation URL.
- No service implementation or deployment configuration is present here.

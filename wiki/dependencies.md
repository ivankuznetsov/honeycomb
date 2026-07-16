# Dependencies

The registry implementation is deliberately offline and dependency-light.

## Runtime

- Ruby standard/default libraries: Psych/YAML, JSON, Digest, OptionParser,
  Pathname, Set, Tempfile, Time, URI, and filesystem APIs.
- Checked-in `policy/spdx-license-ids.txt`; validation never consults a host or
  online license service.
- Hive is an optional local compatibility dependency. When available, the
  validator loads `hive` and `hive/workflows/descriptor_parser`; ordinary
  absence warns, while `--require-hive` requires it and enforces the manifest's
  SemVer minimum.
- No Gemfile, Bundler runtime, application framework, database, network fetch,
  schema registry, or hidden cache is used.

## Development and CI

`ruby test/run.rb` uses Minitest from Ruby's default library plus stdlib helpers.
The compatible-parser unit seam is injectable, so missing/old/rejecting Hive
states are tested without downloading runtimes. A CI job that invokes
`--require-hive` must install the pinned supported Hive version separately.

## Services

- `hive.sh/honeycombs` is the documented catalog surface.
- GitHub URLs in generated catalog entries are deterministic strings; catalog
  generation never calls GitHub.
- No service implementation or deployment configuration is present here.

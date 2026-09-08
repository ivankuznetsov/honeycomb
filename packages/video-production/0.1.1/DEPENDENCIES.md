# Video Production dependency disclosure

## Package runtime

The package tools use Ruby standard/default libraries only: Base64, Digest,
FileUtils, JSON, OpenSSL, OptionParser, Pathname, and Shellwords. They have no
gem, network service, source checkout, private harness, or Hive source-tree
runtime dependency. The package carries its complete behavior in its manifest-
hashed workflow, instructions, non-executable shared implementation, and five
stage-specific executable wrappers.

## Trusted owner host

Capture requires `docker`, `asciinema`, `agg`, `ffmpeg`, and `ffprobe` on the
host. The project must also provide an already-present digest-pinned container
image, a pre-hardened snapshot directory, and a public-only Ed25519 PEM or DER
key. Parsed private key material is rejected regardless of encoding. The
corresponding private key is an owner-controlled external dependency and must
not be available to the repository, task, workflow actor, or agent runtime. The
package verifies detached signatures but provides no signing operation.

The tool checks declarations but does not install, fetch, prepare, or mutate
them. It privately stages and hashes the source tree before requesting capture
approval. Every spawned command has bounded process-group, stream-reader, and
container-cleanup deadlines. Capture probes the process group after normal
leader exit, and container absence requires conclusive removal or an exact
Docker no-such result for the recorded ID; unknown inspection failures fail
closed. Every failed or interrupted allocated take remains as recovery
evidence, including pure-Ruby post-approval preflight and initialization paths.

The manifest may opt into three package-declared environment bindings:
`VIDEO_CAPTURE_USERNAME`, `VIDEO_CAPTURE_PASSWORD`, and
`VIDEO_CAPTURE_TOKEN`. Only the capture slot is authorized. Values remain
runtime-only and are forwarded by environment name when present.

## Explicit absences

The workflow has no automated distribution, remote-write, social, release,
deployment, or catalogue operation. Its terminal output is local
`publish-ready.json` with `published: false`. Human authority is required for
any later use of the verified artifacts.

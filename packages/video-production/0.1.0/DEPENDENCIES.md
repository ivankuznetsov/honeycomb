# Video Production dependency disclosure

## Package runtime

`tools/video-production.rb` uses Ruby standard/default libraries only: Digest,
FileUtils, JSON, Open3, OptionParser, Pathname, Shellwords, and Timeout. It has
no gem, network service, source checkout, private harness, or Hive source-tree
runtime dependency. The package carries its complete behavior in its manifest-
hashed workflow, instructions, and executable tool.

## Trusted owner host

Capture requires `docker`, `asciinema`, `agg`, `ffmpeg`, and `ffprobe` on the
host. The project must also provide an already-present digest-pinned container
image and an immutable pre-hardened snapshot. The tool checks these declarations
but does not install, fetch, prepare, or mutate them. Every spawned command has
the manifest's bounded timeout, and every failed allocated take remains as
recovery evidence.

The manifest may opt into three package-declared environment bindings:
`VIDEO_CAPTURE_USERNAME`, `VIDEO_CAPTURE_PASSWORD`, and
`VIDEO_CAPTURE_TOKEN`. Only the capture slot is authorized. Values remain
runtime-only and are forwarded by environment name when present.

## Explicit absences

The workflow has no automated distribution, remote-write, social, release,
deployment, or catalogue operation. Its terminal output is local
`publish-ready.json` with `published: false`. Human authority is required for
any later use of the verified artifacts.

# Video Production 0.1.0

Video Production turns a project-owned media manifest into deterministic dry-
run evidence, a fingerprint-approved trusted-owner capture, verified terminal
media, a second fingerprint-approved editorial decision, and a local
`publish-ready.json` handoff. It is a broad reusable Honeycomb: all workflow
instructions and executable capture/verification behavior are contained in
this package, with no runtime dependency on a private recording harness.

The package does not upload, post, publish, merge, deploy, or release anything.
It never prepares images, installs software, or stores credentials. The owner
supplies the manifest, a pre-hardened snapshot, an already-present digest-
pinned image, and any short-lived runtime-only optional values injected at
execution.

## Trust and approval boundary

Capture is a trusted owner operation, not an OS sandbox. Its Hive stage is
explicitly high risk because it starts a container and records an owner-chosen
command. The container's configured network mode and read-only snapshot mount
are operational controls, not a security boundary. Only an owner who
understands the image, snapshot, command, environment, target repository, and
recovery state should check the capture approval.

Both approval stages create a checklist plus `WAITING`. A checked capture
approval binds the exact workflow identity, manifest SHA-256, packaged tool
SHA-256, scene command SHA-256, image, snapshot SHA-256, and fingerprint. A
checked editorial approval binds the exact verified artifact hashes and
verification SHA-256. The tool recomputes and compares those values on the
explicit rerun; changing the manifest, tool, snapshot, command, or evidence
invalidates the old approval.

## Host prerequisites

The package uses only Ruby standard/default libraries itself. The trusted owner
must provide these host executables before capture:

- Docker with the declared digest-pinned image already present;
- asciinema for the `.cast` recording;
- `agg` for GIF rendering;
- ffmpeg for H.264/yuv420p MP4 encoding with even dimensions; and
- ffprobe for playability, codec, pixel format, dimension, and duration checks.

The project manifest may pass only `VIDEO_CAPTURE_USERNAME`,
`VIDEO_CAPTURE_PASSWORD`, and `VIDEO_CAPTURE_TOKEN`, and only to the capture
slot. Values are resolved at runtime and forwarded by name; they never enter
the package, manifest, approval, hashes, or generated media metadata, and the
tool redacts their current values from its command log. The captured command can
still render sensitive content into terminal media, so editorial inspection is
mandatory. See `DEPENDENCIES.md` for the full dependency and absence contract.

## Project media manifest

Create `media-manifest.json` in the project. Paths are normalized relative to
that file. `capture.snapshot` names a regular file or directory, and the image
must include a `sha256` digest. Commands are argv arrays, never shell strings.

```json
{
  "schema": "hive-video-production/v1",
  "project": "example-project",
  "output_dir": "media",
  "capture": {
    "image": "registry.example/video@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "snapshot": "snapshot",
    "network": "none",
    "timeout_seconds": 300,
    "environment": []
  },
  "scenes": [
    {
      "id": "product-demo",
      "title": "Product demo",
      "duration_seconds": 90,
      "columns": 120,
      "rows": 36,
      "command": ["bin/demo", "--scenario", "product-demo"]
    }
  ]
}
```

The tool's `--help` lists the six operations. Start with `validate` and
`dry-run`; dry-run reads and hashes the snapshot but performs no write, take
allocation, dependency probe, container activity, or media command. Capture
allocates `output_dir/<scene>/take-NNNN` with an atomic directory create.
Failures preserve their take, `capture.log`, context, and `failure.json`; a
retry uses a new take.

Verification writes durable JSON for the workflow, manifest, tool, paths,
hashes, errors, and MP4 inspection. The final command validates the checked
editorial fingerprint and writes only `publish-ready.json` locally.

## Registry-original manifest finalization

`manifest.yml` is intentionally a source-commit seed. Its two
`SOURCE_COMMIT_REQUIRED` values cannot be replaced until the behavior-bearing
files have a real Git revision. After the owner creates that source commit, run
these exact commands from the repository root before the separate manifest
commit:

```sh
source_revision="$(git rev-parse HEAD)"
ruby -e 'path, revision = ARGV; bytes = File.binread(path); raise "unexpected seed" unless bytes.scan("SOURCE_COMMIT_REQUIRED").length == 2; File.binwrite(path, bytes.gsub("SOURCE_COMMIT_REQUIRED", revision))' packages/video-production/0.1.0/manifest.yml "$source_revision"
ruby script/honeycomb-manifest packages/video-production/0.1.0
ruby script/honeycomb-manifest --check packages/video-production/0.1.0
ruby script/honeycomb-validate packages/video-production/0.1.0
```

The source and manifest commits are distinct so `source.revision` is real
registry-original provenance rather than a fabricated digest. Package presence
and local validation do not claim catalogue listing, review, public
installation, or publication.

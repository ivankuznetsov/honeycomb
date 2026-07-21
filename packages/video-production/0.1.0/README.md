# Video Production 0.1.0

Video Production turns a project-owned media manifest into deterministic dry-
run evidence, a signed trusted-owner capture request, verified terminal media,
a second signed editorial decision, and a local
`publish-ready.json` handoff. It is a broad reusable Honeycomb: all workflow
instructions and executable capture/verification behavior are contained in
this package, with no runtime dependency on a private recording harness.

The package does not upload, post, publish, merge, deploy, or release anything.
It never prepares images, installs software, or stores credentials. The owner
supplies the manifest, a pre-hardened snapshot directory, an Ed25519 public
key, an already-present digest-pinned image, and any short-lived runtime-only
optional values injected at execution.

## Trust and approval boundary

Capture is a trusted owner operation, not an OS sandbox. Its Hive stage is
explicitly high risk because it starts a container and records an owner-chosen
command. The container's configured network mode and read-only snapshot mount
are operational controls, not a security boundary. Only an owner who
understands the image, snapshot, command, environment, target repository, and
recovery state should sign a capture request.

Both approval stages create an unchecked request plus `WAITING`. The owner
changes only the exact stage-specific sentence to `[x]`, then signs the entire
checked Markdown file with the detached Ed25519 private key. The package takes
the checked request and detached signature as separate inputs, verifies them
against `capture.owner_public_key`, and never signs anything. The private key
must stay outside the repository, Hive task, agent-readable filesystem, and
agent runtime; the package rejects private key material even when it is encoded
as DER. An agent-visible private key destroys the owner-only boundary. The
receipt is the raw detached signature bytes. For example, an owner may copy the
request to a protected environment, check the exact sentence there, and use
OpenSSL 3 without exposing the private key to Hive:

```sh
openssl pkeyutl -sign -rawin -inkey owner-private.pem \
  -in capture-approval.md -out capture-approval.sig
```

The checked Markdown and resulting `.sig` return as separate inputs; changing
either file after signing invalidates the receipt.

A capture request reserves one exact take and copies the declared directory to
a private staged snapshot before signing. Its typed tree digest includes empty
directories, paths, modes, sizes, and file digests. The signed request binds
that staged tree, take, output paths, workflow identity, manifest/tool/command
hashes, image, network, owner public-key hash, and fingerprint. Editorial
approval binds the completed capture context/receipt, verification, artifact
hashes, and the original capture approval identity. Any drift invalidates the
receipt. Every bound value is rendered in the human-readable request as well as
its canonical `Context-JSON`; the checked request must be the exact canonical
rendering, so the display cannot contradict the signed context.

Workflow stages can execute only their stage-specific wrapper. The shared
implementation is intentionally non-executable. Capture is permission-scoped
to reading, listing, its exact wrapper, and writing `capture.md`; it cannot edit
the manifest, owner key, packaged tools, approval request, or evidence files.
This narrows the workflow actor without turning the high-risk container capture
into an OS sandbox, and the actor still cannot mint the detached owner receipt.

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
that file. `capture.snapshot` names a non-symlink directory,
`capture.owner_public_key` names a public-only Ed25519 PEM or DER file, and the
output and snapshot paths must not overlap. Parsed private-key material is
rejected regardless of encoding. The image must include a `sha256` digest.
Commands are argv arrays, never shell strings.

```json
{
  "schema": "hive-video-production/v1",
  "project": "example-project",
  "output_dir": "media",
  "capture": {
    "image": "registry.example/video@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "owner_public_key": "owner-public.pem",
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

The shared tool's `--help` lists the logical operations, but normal workflow
use goes through `video-prepare.rb`, `video-approval-request.rb`,
`video-capture.rb`, `video-verify.rb`, and `video-publish-ready.rb`. Start with
`validate` and `dry-run`; dry-run reads and hashes the snapshot but performs no
write, take allocation, dependency probe, container activity, or media command.
The capture approval request atomically allocates
`output_dir/<scene>/take-NNNN`, reserves it, and stages the exact source tree.

Capture streams bounded diagnostics, supervises the child process group with
bounded TERM/KILL and reader deadlines, probes for descendants even after the
group leader exits, and uses a take-local Docker cidfile. Every terminal path
performs a separately bounded `docker rm -f` plus absence check. Only successful
removal or an exact Docker "No such container/object" result for that ID proves
absence; daemon, permission, timeout, spawn, and unknown inspection failures
remain incomplete. Failures and interrupts preserve their take, bounded
`capture.log`, context, cleanup state, and `failure.json`; a raw interrupt after
approval exits 130 with durable failure evidence. Retry is blocked when process
or container cleanup cannot be proved complete; otherwise it requires a newly
staged and signed take. Post-approval host preflight failures also consume their
reserved take and require new approval.

Verification rejects synthetic, running, and failed takes. It requires the
completed capture context and receipt chain, then writes durable JSON for the
workflow, manifest, tool, staged snapshot, approval identity, paths, hashes,
errors, and MP4 inspection. The final command validates the signed editorial
request and the unchanged evidence chain, then writes only
`publish-ready.json` locally.

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

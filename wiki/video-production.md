# Video Production Honeycomb

`packages/video-production/0.1.0` is a reusable, high-risk workflow candidate
for manifest-bounded terminal video capture. The workflow is:

`Inbox -> Prepare -> Capture approval -> Capture -> Verify -> Editorial approval -> Publish-ready`

It carries all runtime instructions and executable behavior inside the package.
No source checkout or private recording harness is required at runtime.

## Project contract

The project owns `media-manifest.json`, a pre-hardened snapshot directory, a
public-only Ed25519 key, an already-present digest-pinned container image, and
output storage. The corresponding owner private key must remain outside the
repository, task, workflow actor, and agent runtime. The strict JSON manifest
names a project, normalized disjoint snapshot/output paths, capture timeout,
network mode, sorted package-declared optional environment names, and one or
more scenes. Each scene has a portable ID, title, duration, terminal dimensions,
and an argv command.

`tools/video-prepare.rb validate` checks shape without side effects. `dry-run`
additionally hashes the typed snapshot tree, manifest, complete packaged
toolset, owner public key, and scene command and emits deterministic paths for
the next take without allocating it or invoking host commands. The shared
implementation is non-executable; five stage-specific wrappers are the declared
workflow tools.

## Approval and execution identity

`video-approval-request.rb` reserves one exact take, privately stages the source
tree, and writes an unchecked request plus `WAITING`. Capture approval binds:

- `video-production@0.1.0` and the scene ID;
- manifest, complete toolset, command, and owner public-key SHA-256 values;
- the digest-pinned image, network, typed staged-tree SHA-256, reserved take,
  and exact artifact paths; and
- the canonical approval fingerprint.

The approval Markdown renders every bound field in a deterministic human-
readable form followed by canonical `Context-JSON`. Capture recomputes the
complete request and accepts only its exact checked rendering, preventing a
signed display from contradicting the opaque context. Public keys may be PEM or
DER, but parsed private-key material is rejected in either encoding.

Only a human owner may change the exact owner sentence to `[x]` and produce a
detached Ed25519 signature over those complete bytes. The package verifies the
receipt and provides no signing operation. `video-capture.rb` recomputes every
value before host activity and rejects stale, mismatched, unsigned, unrelated,
or duplicate approval state. The original mutable source may then drift or
disappear because capture mounts only the signed staged tree.

Capture checks the five declared host executables, records running and completed
capture context plus a capture receipt, and bounds Docker image inspection,
asciinema, agg, ffmpeg, process-group termination, pipe-reader completion, and
diagnostic retention. It probes the group after a normal leader exit so live
descendants are terminated before success. A take-local cidfile drives a
separately bounded `docker rm -f` and absence check on every terminal path.
Only a successful removal or an exact Docker no-such result for that ID proves
absence; unknown, daemon, permission, timeout, and spawn failures fail closed. A
failure or interrupt preserves the take, bounded log, context, cleanup status,
and `failure.json`; raw interrupts after approval, including during output-reader
startup, terminate the process group and exit 130. Retry is blocked
unless process and container cleanup are both proven complete, and every retry,
including host-preflight failure, requires a newly reserved, staged,
owner-signed take.

The capture actor is permission-scoped to reading, listing, the exact capture
wrapper, and `capture.md`; it cannot edit the manifest, owner key, packaged
tools, approval, or evidence. Its image, mount, and network choices are still
operational controls, not an OS sandbox. Optional username, password, and token
values are authorized only for `stages.capture`, forwarded by environment name
when present, and excluded from durable evidence.

## Verification and terminal boundary

`video-verify.rb` rejects synthetic, running, and failed takes. It validates the
capture context/receipt, signed capture identity, staged snapshot, and selected
take before requiring non-empty `.cast`, GIF, log, and MP4 files. ffprobe must
report a playable positive-duration H.264/yuv420p stream with positive even
dimensions. The command writes `verification.json` and `hashes.json` on both
valid and invalid outcomes. Editorial approval is another detached owner
signature binding the capture chain, verified evidence file, and all artifact
hashes.

`video-publish-ready.rb` checks that second approval and the complete unchanged
capture/verification chain, then writes a local
`publish-ready.json` record with `published: false`. It invokes no host command
and grants no upload, posting, merge, deployment, release, or catalog authority.

## Provenance and rollout state

Registry-original packages require two commits. The checked-in `manifest.yml`
binds the generated package to its immutable `source.revision`; the generated
manifest was committed separately. A disposable unrelated project materialized
the package through Hive 0.6.5, installed all six mapped slots, created a managed
task with immutable catalog/manifest/configuration pins, preserved executable
wrapper modes, and kept optional values absent and capture-only. The local
registry entry used for that proof was synthetic and does not claim listing or
publication.

Guarded real capture, external owner-key handling, protected review, and catalog
evidence remain incomplete. Package presence and local installation proof do
not establish listing, publication, or approval for real capture.

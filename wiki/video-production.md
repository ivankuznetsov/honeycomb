# Video Production Honeycomb

`packages/video-production/0.1.0` is a reusable, high-risk workflow candidate
for manifest-bounded terminal video capture. The workflow is:

`Inbox -> Prepare -> Capture approval -> Capture -> Verify -> Editorial approval -> Publish-ready`

It carries all runtime instructions and executable behavior inside the package.
No source checkout or private recording harness is required at runtime.

## Project contract

The project owns `media-manifest.json`, a pre-hardened snapshot, an already-
present digest-pinned container image, and output storage. The strict JSON
manifest names a project, output directory, capture timeout, network mode,
sorted package-declared optional environment names, and one or more scenes.
Each scene has a portable ID, title, duration, terminal dimensions, and an argv
command.

`tools/video-production.rb validate` checks shape without side effects.
`dry-run` additionally hashes the snapshot, manifest, packaged tool, and scene
command and emits deterministic paths for the next take without allocating it
or invoking host commands.

## Approval and execution identity

`approval-template` writes a checklist plus `WAITING`. Capture approval binds:

- `video-production@0.1.0` and the scene ID;
- manifest, tool, and command SHA-256 values;
- the digest-pinned image and snapshot SHA-256; and
- the canonical approval fingerprint.

Only a human owner checks the box. `capture` recomputes every value before host
activity and rejects stale or mismatched approval. It checks the five declared
host executables, atomically allocates `take-NNNN`, records capture context, and
bounds Docker image inspection, asciinema, agg, and ffmpeg by the manifest
timeout. A failure preserves the take, log, context, and `failure.json`; retry
allocates a new take.

The capture actor is deliberately `yolo`. Its image, mount, and network choices
are operational controls, not an OS sandbox. Optional username, password, and
token values are authorized only for `stages.capture`, forwarded by environment
name when present, and excluded from durable evidence.

## Verification and terminal boundary

`verify` requires non-empty `.cast`, GIF, log, and MP4 files. ffprobe must report
a playable positive-duration H.264/yuv420p stream with positive even dimensions.
The command writes `verification.json` and `hashes.json` on both valid and
invalid outcomes. Editorial approval binds the verified evidence file and all
artifact hashes.

`publish-ready` checks that second approval and writes a local
`publish-ready.json` record with `published: false`. It invokes no host command
and grants no upload, posting, merge, deployment, release, or catalog authority.

## Provenance and rollout state

Registry-original packages require two commits. The checked-in `manifest.yml`
is a transparent seed with exactly two `SOURCE_COMMIT_REQUIRED` values. After a
real behavior-source commit, the owner replaces those values with that exact
revision, runs `script/honeycomb-manifest`, and commits the generated manifest
separately. Focused tests prove this flow in an ephemeral Git registry without
inventing the actual revision.

Until that canonicalization, clean unrelated Hive installation, guarded real
capture, protected review, and catalog evidence are complete, package presence
does not establish installability, listing, or publication.

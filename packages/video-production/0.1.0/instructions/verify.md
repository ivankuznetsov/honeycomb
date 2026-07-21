# Verify captured media

Read `capture.md` and stop with `Workflow-Status: waiting` unless it identifies
one completed take. Run only the declared `tools/video-production.rb verify`
command for that exact manifest, scene, and take.

The tool must require non-empty cast, GIF, log, and MP4 files, inspect the MP4
with the declared `ffprobe` prerequisite, require a playable positive-duration
H.264 stream with `yuv420p` and positive even dimensions, and write both
`verification.json` and `hashes.json`. Process exit alone is not proof.

If verification reports `invalid`, preserve its JSON and all take evidence,
then return `verification.md` with `Workflow-Status: recoverable-error` and the
exact defects. If it reports `verified`, return `verification.md` with
`Workflow-Status: verified`, the manifest and tool hashes, media inspection,
artifact hashes, and verification path. Never repair media in place; a new
capture receives a new take.

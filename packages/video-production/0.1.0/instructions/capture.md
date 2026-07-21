# Run the approved trusted-owner capture

Read `preparation.md`, `capture-approval.md`, and its detached owner signature.
Run only the declared `tools/video-capture.rb` wrapper for the prepared
manifest and scene, passing both approval and receipt paths. The tool must
validate the exact checked sentence, Ed25519 signature, fingerprint, reserved
take, and staged-tree digest before host activity; require the declared host
prerequisites; and inspect the already-present digest-pinned image.

This is a trusted owner operation, not an OS sandbox. Hive permissions allow
reading, listing, the exact capture wrapper, and writing `capture.md`; they do
not authorize editing the manifest, owner key, packaged tools, approval, or
evidence. Do not run an equivalent capture command manually, install anything,
alter the staged snapshot, prepare an image, or persist secret values. Only the
manifest's approved environment names may flow from current runtime input to
the container. The tool uses a take-local cidfile, bounded process-group cleanup
that also checks for descendants after leader exit, bounded diagnostics, and a
separately bounded container removal/absence check. Only conclusive removal or
Docker's exact no-such result for that container ID proves cleanup complete.

On success, preserve the tool's JSON plus the `.cast`, GIF, MP4, log, and
capture-context and capture-receipt paths in `capture.md` with
`Workflow-Status: captured`. On failure, do not overwrite or delete the failed
take. Record `Workflow-Status: recoverable-error`, `failure.json`, the retained
log, cleanup completeness, and the owner action needed before an explicit
retry. Pure-Ruby interrupts after approval must also preserve `failure.json` and
exit 130. Never retry when cleanup is incomplete. Every retry, including one
after a post-approval host-preflight failure, requires a newly reserved, staged,
and owner-signed take.

# Run the approved trusted-owner capture

Read `preparation.md` and `capture-approval.md`. Run only the declared
`tools/video-production.rb capture` command for the prepared manifest and
scene. The tool must validate the checked fingerprint before host activity,
require the declared host prerequisites and snapshot, inspect the already
present digest-pinned image, allocate a unique take atomically, and enforce the
manifest timeout around every command.

This is a trusted owner operation with unbounded Hive permissions, not an OS
sandbox. The packaged tool is the execution boundary: do not run an equivalent
capture command manually, install anything, alter the snapshot, prepare an
image, or persist secret values. Only the manifest's approved environment names
may flow from current runtime input to the container.

On success, preserve the tool's JSON plus the `.cast`, GIF, MP4, log, and
capture-context paths in `capture.md` with `Workflow-Status: captured`. On
failure, do not overwrite or delete the failed take. Record `Workflow-Status:
recoverable-error`, `failure.json`, the retained log, and the owner action
needed before an explicit retry. A retry must allocate a new take.

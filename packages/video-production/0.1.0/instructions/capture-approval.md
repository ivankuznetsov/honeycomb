# Request capture approval

Read `preparation.md` and stop unless it says `Workflow-Status: prepared` and
the referenced dry-run evidence still matches the project manifest and scene.
Run only the declared `tools/video-production.rb approval-template` command for
the `capture` stage. Write the resulting checklist to `capture-approval.md`.
The tool also writes executable `WAITING` state bound to the workflow,
manifest, tool, scene command, image, snapshot, and fingerprint.

Do not check the box. A human owner must inspect the exact command, image,
snapshot, runtime-only environment names, output paths, and risk disclosure,
then change the one checklist box to `[x]`. An agent statement, task status, or
approval for an older fingerprint is not authorization. End this run with
`Workflow-Status: waiting`; only an explicit rerun after the owner edit may
advance.

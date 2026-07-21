# Request editorial approval

Read `verification.md` and stop unless it says `Workflow-Status: verified` and
the selected `verification.json` still matches the current manifest, tool,
scene, take, and artifact hashes. Run only the declared
`tools/video-production.rb approval-template` command for the `editorial`
stage, passing that verification file. Write the checklist to
`editorial-approval.md`; the tool also writes `WAITING` state bound to the
verification and artifact hashes.

Do not check the box. A human owner must review the complete recording and its
evidence, then change the one checklist box to `[x]`. Textual praise, an older
approval, or a checked box with a different fingerprint is not authorization.
End this run with `Workflow-Status: waiting`; only an explicit rerun after the
owner edit may advance.

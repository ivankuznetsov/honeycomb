# Request editorial approval

Read `verification.md` and stop unless it says `Workflow-Status: verified` and
the selected `verification.json` still matches the current manifest, tool,
scene, take, and artifact hashes. Run only the declared
`tools/video-approval-request.rb` wrapper for the `editorial` stage, passing
that verification file and `editorial-approval.md` as its output. The tool also
writes `WAITING` state bound to the capture context/receipt, capture approval,
staged snapshot, verification, and artifact hashes.

Do not check, edit, or sign the request. A human owner must review the complete
recording and evidence, then outside the agent runtime change only the exact
owner sentence to `[x]` and create a detached Ed25519 signature over every byte
of the checked file. Textual praise, an agent-generated receipt, an older
approval, or a receipt for different bytes is not authorization. End with
`Workflow-Status: waiting`; only an explicit rerun with both owner files may
advance.

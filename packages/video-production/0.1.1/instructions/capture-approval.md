# Request capture approval

Read `preparation.md` and stop unless it says `Workflow-Status: prepared` and
the referenced dry-run evidence still matches the project manifest and scene.
Run only the declared `tools/video-approval-request.rb` wrapper for the
`capture` stage, with `capture-approval.md` as its output. The tool reserves the
exact take, privately stages the exact snapshot directory, and writes `WAITING`
state bound to the workflow, manifest, tool, scene command, image, staged tree,
take, artifact paths, owner public key, and fingerprint.

Every bound field appears in the human-readable request and in canonical
`Context-JSON`. Inspect both forms and reject any contradiction; capture accepts
only the exact canonical checked rendering, not merely a signature over edited
display text.

Do not check, edit, or sign the request. A human repository owner must inspect
the exact command, image, network, staged snapshot digest, runtime-only
environment names, reserved take, output paths, and risk disclosure. Outside
the agent runtime, the owner changes only the exact owner sentence to `[x]` and
creates a detached Ed25519 signature over every byte of that checked Markdown
file. The private key must never be exposed to this task or any workflow actor.
An agent-created signature, task status, unsigned checkbox, or receipt for
different bytes is not authorization. End with `Workflow-Status: waiting` and
the expected receipt path; only an explicit rerun with both files may advance.

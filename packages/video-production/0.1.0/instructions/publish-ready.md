# Record the local publish-ready outcome

Read `verification.md` and `editorial-approval.md`. Run only the declared
`tools/video-publish-ready.rb` wrapper with the exact manifest, scene, take,
verification, checked editorial approval, and detached owner signature. The
tool must reject approval, capture context/receipt, staged snapshot,
verification, artifact, or fingerprint drift and write `publish-ready.json`
inside the selected take.

Return that same JSON as the stage deliverable. Its only successful status is
`publish-ready`, and `published` must remain `false`. This terminal stage is a
local evidence handoff. It does not confer authority for any network or remote
operation, private-to-public selection, permission change, or release action.
Do not substitute console output for the manifest, tool, approval,
verification, artifact hashes, and local artifact paths preserved in the
deliverable.

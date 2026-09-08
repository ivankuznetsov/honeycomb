# Measure the draft

Read `draft.md`, `intent.md`, and the declared `assets/quality-rubric.md` prompt
asset. Run only the declared `tools/seo-analyze.rb` executable against
`draft.md`, passing the selected primary keyword with `--keyword` when one was
selected. Read its JSON output; do not recreate or modify the tool.

Return `analysis.md` with measured values, rubric comparisons, severity, and a
prioritized recommendation for every meaningful finding. End with
`<!-- COMPLETE -->`.

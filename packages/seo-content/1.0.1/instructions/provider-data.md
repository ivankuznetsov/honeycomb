# Collect optional provider metrics

Read `brief.md` and the optional-input availability in the package preamble.
Never print, quote, persist, or expose credential values.

Build a minimal JSON request containing `keywords`, `site_url`, `start_date`,
and `end_date` where the brief supplies them. Pipe it to the declared
`tools/provider-metrics.rb` executable and read its sanitized JSON response.
Do not call providers directly or run any other command.

Return `provider-data.md` with mode `prompt-only`, `partial`, or
`provider-backed`; per-provider status; aggregate usable metrics with date
ranges; and limitations. Never infer that a missing provider returned zero.
End with `<!-- COMPLETE -->`.

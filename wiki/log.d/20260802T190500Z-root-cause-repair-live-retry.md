# Root Cause Repair live retry hardening

- Classified managed `refs/llm-wiki/sources/` snapshot movement as unrelated to
  the pinned target, alongside non-current branches and remote-tracking refs.
- Added explicit one-hour bounds for repair and verification after a live repair
  reached the former implicit 30-minute default during final evidence review.
- Documented that partial target bytes not advanced before a failed attempt
  remain unattributed and therefore block until owner reconciliation or a fresh
  baseline; retries do not silently adopt them.

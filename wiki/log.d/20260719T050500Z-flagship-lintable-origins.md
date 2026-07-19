## 2026-07-19 — Make flagship behavior statically reviewable

- Expressed every SEO provider endpoint through fixed origin constants so the
  inert security scanner can prove the complete host set while runtime paths
  and query parameters remain bounded and dynamic.
- Reworded one Writing rubric sentence that began with the shell builtin
  `source` and was therefore correctly treated as command-like text.
- Added a package regression requiring all provider observations to resolve to
  the four documented concrete hosts.

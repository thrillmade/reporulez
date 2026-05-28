## 2026-05-28 13:16 - chore: clud-bug v0.5.15 → v0.6.12 (full Phase A propagation)

**Reasoning:** First end-to-end Phase A propagation to this consuming repo. 10 files changed: 3 workflow YAMLs re-rendered to v0.6.12 templates; AGENTS.md + 5 per-tool rules files (.cursorrules, .clinerules, .continuerules, .windsurfrules, .github/copilot-instructions.md) trimmed to v0.6.6 v2 block format; .clud-bug.json stamped @v0.6.12. Lands all Phase A wins: caching (v0.6.3), per-section budgets (v0.6.4), comment compression with severity tiers (v0.6.5), AGENTS-block trim (v0.6.6), CLUD_BUG_QUIET CLI (v0.6.7), --max-turns 15 + MAX_THINKING_TOKENS=8000 (v0.6.8), incremental-diff handshake (v0.6.10), Sonnet 4.6 pin (v0.6.11), self-update YAML fix (v0.6.12).

---

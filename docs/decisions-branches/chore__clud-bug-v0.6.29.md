## 2026-05-31 14:20 - chore: propagate clud-bug v0.6.29 (skill-usage workflow integration)

**Reasoning:** v0.6.29 adds workflow post-step that pipes structured_output through update-skill-usage CLI + uploads .clud-bug.json as 90-day artifact

**Implications:**
- Reporulez consumer-side propagation; multi-harness repo (.cursorrules, .clinerules, .continuerules, .windsurfrules, copilot-instructions.md) refreshes all in sync

---

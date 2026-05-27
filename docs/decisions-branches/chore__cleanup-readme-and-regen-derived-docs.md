## 2026-05-27 13:51 - chore: correct README workaround claims (bot review) + regen docs/file-structure.md without stale Last updated line

**Reasoning:** Also: regenerate docs/file-structure.md to drop the stale 'Last updated:' line — committed under v0.3.0/0.3.1 era, v0.3.3 dropped the line from the template. The local post-merge hook v0.3.3 was producing a clean version every pull, creating perpetual dirty state. Pushing the clean version fixes it forever for this repo

**Implications:**
- Same regen-strip cleanup will need to ship for clud-bug, agent-skills, rezgen, and logmind in separate small PRs

---

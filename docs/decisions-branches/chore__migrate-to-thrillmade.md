## 2026-05-26 22:06 - chore: migrate to thrillmade org

**Reasoning:** Move 6 of the thrillmade migration. Repo transferred thrillmot/reporulez → thrillmade/reporulez. This PR updates all GitHub-org refs: bin/apply.sh's REPORULEZ_RAW_BASE default (the runtime-critical one — that's what curl pipelines fetch from), README curl examples, AGENTS.md/CLAUDE.md/copilot-instructions, the embedded clud-bug-collaboration SKILL.md cache, and the clud-bug-review workflow header. Also picks up v0.3.0 refresh (logmind-self-update.yml installed, AGENTS.md → v4-slim, .gitattributes merge-driver block, post-merge hook). Existing curl-pipe invocations in installed repos continue to work via GitHub redirect; new invocations should use the thrillmade path.

**Alternatives considered:** Leave REPORULEZ_RAW_BASE default at thrillmot and rely on GitHub redirect forever — fragile; explicit canonical path is better, Defer to a separate PR — would leave the migration in an awkward half-state where the org transferred but the repo's own curl examples + apply.sh default still pointed at old org

**Implications:**
- Future curl … apply.sh invocations canonically use thrillmade/reporulez raw URLs
- REPORULEZ_RAW_BASE env var still lets users override the default at apply time (unchanged contract)
- Vestigial repo-level reporulez-default ruleset (id 16432559) deleted post-transfer; org-level org-default-protection now governs alone

---

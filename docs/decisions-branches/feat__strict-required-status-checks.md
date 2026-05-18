## 2026-05-18 12:05 - Add clud-bug-logmind variant to reporulez (canonical bundle for repos using both tools)

**Reasoning:** Strict mode (strict_required_status_checks_policy: true) is load-bearing for logmind v0.2's per-PR derived-file model. Without rebase-before-merge, two PRs touching docs/timeline.md concurrently would both pass check-derived-docs independently and then deadlock on conflicting regens at merge time. Strict-mode rebase eliminates the race — what v0.2's architecture leans on.

**Alternatives considered:** Modify external.json directly to add the rule — rejected because external is meant for any non-Copilot AI reviewer (CodeRabbit, Cursor, Claude Code Review App), not specifically clud-bug+logmind. Adding clud-bug-specific contexts there would break non-clud-bug users of external. A new variant keeps each audience's variant clean., Document the canonical contexts as a manual after-install step in README — rejected as low-value when a one-flag variant choice eliminates the manual step. The README still documents this for repos that DON'T have clud-bug+logmind.

**Implications:**
- bin/apply.sh accepts the new variant alongside copilot|external. CLI surface grows by one option but the case statement and JSON-fetch path are unchanged shape.
- If a user adopts this variant on a repo that doesn't actually have all four workflows installed, the missing contexts will fail the required-checks rule and block merges. That's the desired behavior — pick this variant only after confirming both tools' init has been run.

---

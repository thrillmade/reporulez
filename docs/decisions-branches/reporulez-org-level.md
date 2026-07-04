← back to [docs/timeline.md](../timeline.md)

## 2026-07-04 00:30 - reporulez: org-level baseline ruleset support (apply-org.sh + org-baseline.json)

**Reasoning:** Protect a whole org in one command; today reporulez is repo-level only (one apply.sh run per repo). org-baseline is a minimal structural FLOOR: targets repository_name ~ALL so every repo incl. future ones is covered, plus an OrganizationAdmin bypass (bypass_mode=always) to unstick edge cases. It omits the linear-history/squash-only/thread-resolution opinions the per-repo variants carry so it never breaks a repo that wants merge commits. bin/apply-org.sh mirrors apply.sh (local-first-else-curl JSON load, find-by-name, create-if-absent POST / update-if-present PUT via orgs/<org>/rulesets, idempotent). admin:org preflight is the ruleset LIST call itself (403s without the scope) — dies pointing at 'gh auth refresh -h github.com -s admin:org'.

**Alternatives considered:** One org-level variant per repo variant (clud-bug/skdd/public-guard at org scope), Add an --org flag to apply.sh instead of a separate script

**Implications:**
- Org-level and repo-level rulesets LAYER — apply-org.sh never touches/overrides per-repo rulesets from apply.sh; a write must satisfy both
- apply-org.sh deliberately does NOT PATCH per-repo settings (auto-merge/squash-only/delete-on-merge) — those are repo-scoped with no org equivalent
- Org variants beyond org-baseline are out of scope for now; requires admin:org scope + org ownership

---


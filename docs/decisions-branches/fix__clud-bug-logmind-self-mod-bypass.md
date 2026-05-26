## 2026-05-26 15:23 - Add --bypass-admin flag to apply.sh for clud-bug self-mod ceremonies

**Reasoning:** clud-bug's review action 401s on PRs that edit .github/workflows/clud-bug-*.yml by design (self-mod guard). The required clud-bug-review check then fails and merge deadlocks against required_status_checks. The clud-bug-logmind variant currently ships bypass_actors=[] so the only escape hatches are intrusive (hand-PATCH the ruleset mid-merge, or globally disable enforcement to merge). A first-class --bypass-admin flag adds Repository admin (RepositoryRole id=5, bypass_mode=always) so admins can merge stuck self-mod PRs without touching the ruleset.

**Alternatives considered:** Hardcode bypass_actors into rulesets/clud-bug-logmind.json so every install gets it by default. Rejected because it would silently change behavior for existing variant users on re-apply, and the --human-review precedent established that opt-in ruleset mutations belong in apply.sh flags rather than variant JSON., Do nothing — keep documenting the manual gh api PATCH workaround. Rejected because every fresh install of the clud-bug-logmind variant repeats the same manual setup.

**Implications:**
- Users adopting the clud-bug-logmind variant should pass --bypass-admin in their install command; README quickstart and post-install footer both surface the recommendation. Flag is variant-agnostic but documented primarily for clud-bug-logmind.
- OrganizationAdmin bypass (actor_type=OrganizationAdmin, actor_id=1) intentionally not included: would 404 on personal-repo installs. RepositoryRole admin works on both personal and org repos. Org-only bypass left as a documented manual follow-up.

---

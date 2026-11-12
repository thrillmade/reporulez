← back to [docs/timeline.md](../timeline.md)

## 2026-09-15 14:29 - Add org-default-protection and org-staging presets, ensure-dev-branch.sh, and docs/branch-policy.md for reporulez#71's org-wide main=production/dev=staging policy

**Reasoning:** Live thrillmade org already runs a working 5-ruleset model (org-baseline+org-default-protection on main, org-staging on dev, plus two repo-level rules) but only org-baseline had a checked-in preset and apply-org.sh variant -- the other two were applied by hand, so the tool couldn't reproduce or audit them. A repo also needs a dev branch before org-staging protects anything there, which no existing script created.

**Alternatives considered:** Fold dev-branch creation into apply-org.sh itself, or make audit.sh's --include-ruleset check dev/default-branch too -- rejected both: apply-org.sh's job is POSTing an org ruleset in one API call, not per-repo branch mutation with per-repo failure modes; and audit.sh is documented read-only, so adding a mutating dev-branch-check duplicates ensure-dev-branch.sh's detection logic in a second place it can drift from.

**Implications:**
- Every org preset (org-baseline, org-default-protection, org-staging, and org-ci-must-pass for the live "CI must pass" ruleset) is re-captured from the live org rulesets, so applying any of them to today's org changes nothing. org-staging's bypass actors are in pull_request mode, as live has them; bin/validate-ruleset.sh's admin-bypass-required check now accepts an admin bypass in always or pull_request mode. The fifth live org ruleset, no-delete-dev-main, has no preset: it carries no bypass actor, which admin-bypass-required refuses.
- bin/apply-org.sh is a dry run by default: it prints the difference between preset and live and writes only with --apply, refusing a duplicate name, a failed live read, or a preset that would remove a bypass actor, ref target or rule, or change a bypass mode from pull_request to always (unless --allow-loosening). bin/ensure-dev-branch.sh is a dry run by default too, creates only with --apply where branches/dev is a 404, skips archived repos and forks, and exits non-zero on any failure. bin/audit.sh reports a failed read as "could not audit" and exits 2. tests/test-org-scripts.sh pins these against a fake gh that records every call.
- ensure-dev-branch.sh warns (never auto-fixes) when a repo's default branch isn't main, surfacing exactly the failure this audit found in one private repository, because flipping a default branch is a human decision this repo's own policy doc says so.

---


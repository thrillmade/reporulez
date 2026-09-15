← back to [docs/timeline.md](../timeline.md)

## 2026-09-15 14:29 - Add org-default-protection and org-staging presets, ensure-dev-branch.sh, and docs/branch-policy.md for reporulez#71's org-wide main=production/dev=staging policy

**Reasoning:** Live thrillmade org already runs a working 5-ruleset model (org-baseline+org-default-protection on main, org-staging on dev, plus two repo-level rules) but only org-baseline had a checked-in preset and apply-org.sh variant -- the other two were applied by hand, so the tool couldn't reproduce or audit them. A repo also needs a dev branch before org-staging protects anything there, which no existing script created.

**Alternatives considered:** Fold dev-branch creation into apply-org.sh itself, or make audit.sh's --include-ruleset check dev/default-branch too -- rejected both: apply-org.sh's job is POSTing an org ruleset in one API call, not per-repo branch mutation with per-repo failure modes; and audit.sh is documented read-only, so adding a mutating dev-branch-check duplicates ensure-dev-branch.sh's detection logic in a second place it can drift from.

**Implications:**
- org-default-protection.json and org-staging.json mirror the bypass_actors actually live today (OrganizationAdmin + RepositoryRole write/admin + the skdd-steward App), not org-baseline.json's narrower single-OrgAdmin convention -- re-running apply-org.sh <org> org-baseline still targets the already-narrower live ruleset and won't touch these two, but that narrowing gap on org-baseline itself is now documented, not fixed, pending a CEO call. ensure-dev-branch.sh warns (never auto-fixes) when a repo's default branch isn't main, surfacing exactly the arlyn-delivery-shaped failure this audit found, because flipping a default branch is a human decision this repo's own policy doc says so.

---


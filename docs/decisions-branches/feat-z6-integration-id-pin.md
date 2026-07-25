← back to [docs/timeline.md](../timeline.md)

## 2026-07-25 15:58 - Z6: pin clud-bug-review required_status_checks to integration_id 3944857 (config only, not applied)

**Reasoning:** context-name-only required_status_checks entries are forgeable -- any token with statuses:write (a PAT, a workflow's default GITHUB_TOKEN, another app) can post a check named clud-bug-review and satisfy the gate, and GitHub resolves a required status check by the latest report for that context, so a forged report posted after the real one wins. Pinning integration_id: 3944857 (the clud-bug[bot] App's own ID) on the clud-bug-review entries in rulesets/clud-bug.json and rulesets/skdd.json means only that App can satisfy the requirement -- GitHub's docs: 'if the status is set by any other person or integration, merging won't be allowed.' Left rulesets/baseline.json, rulesets/public-guard.json, and rulesets/org-baseline.json untouched -- none of them ship a required_status_checks rule at all (SPEC section 7 forbids requiring a check nothing produces), and org-baseline.json in particular mirrors the live org-default-protection ruleset (id 16898453) that the CEO deliberately stripped required_status_checks from org-wide on 2026-07-24 pending clud-bug+logmind launch -- restoring it there would fight that decision. This PR is CONFIG ONLY: no gh api PUT/POST was run against any repo or org ruleset, and bin/apply.sh/apply-org.sh were not invoked. Added bin/verify-integration-id-pin.sh, a forged-vs-genuine verification harness (plan/check/forge subcommands) for later use against a disposable scratch repo once gates return, since a live end-to-end proof requires applying a ruleset (forbidden right now) and installing the real clud-bug App somewhere.

**Alternatives considered:** Skip the integration_id pin and rely on context name alone -- rejected, that is exactly the forgeable gap Z6 exists to close, Also add integration_id to check-derived-docs/check-decisions/check-links in skdd.json -- rejected, those are plain Actions workflow checks with no dedicated App id to pin, and SPEC section 7 forbids pinning a check nothing produces, Apply the updated ruleset to a scratch repo now to get a live proof -- rejected per the build ruling: no live ruleset application while org-wide required_status_checks is deliberately off

**Implications:**
- Once clud-bug + logmind both launch and required_status_checks returns org-wide, re-running bin/verify-integration-id-pin.sh plan/forge/check against a scratch repo becomes the concrete acceptance test for this pin
- Any future new variant that ships a clud-bug-review required check must also carry integration_id: 3944857, or it reopens the same forgery gap

---


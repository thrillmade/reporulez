## 2026-05-18 12:05 - Add clud-bug-logmind variant to reporulez (canonical bundle for repos using both tools)

**Reasoning:** Strict mode (strict_required_status_checks_policy: true) is load-bearing for logmind v0.2's per-PR derived-file model. Without rebase-before-merge, two PRs touching docs/timeline.md concurrently would both pass check-derived-docs independently and then deadlock on conflicting regens at merge time. Strict-mode rebase eliminates the race — what v0.2's architecture leans on.

**Alternatives considered:** Modify external.json directly to add the rule — rejected because external is meant for any non-Copilot AI reviewer (CodeRabbit, Cursor, Claude Code Review App), not specifically clud-bug+logmind. Adding clud-bug-specific contexts there would break non-clud-bug users of external. A new variant keeps each audience's variant clean., Document the canonical contexts as a manual after-install step in README — rejected as low-value when a one-flag variant choice eliminates the manual step. The README still documents this for repos that DON'T have clud-bug+logmind.

**Implications:**
- bin/apply.sh accepts the new variant alongside copilot|external. CLI surface grows by one option but the case statement and JSON-fetch path are unchanged shape.
- If a user adopts this variant on a repo that doesn't actually have all four workflows installed, the missing contexts will fail the required-checks rule and block merges. That's the desired behavior — pick this variant only after confirming both tools' init has been run.

---
## 2026-05-18 12:20 - Fix post-install message + README contradictions for clud-bug-logmind variant

**Reasoning:** Clud Bug flagged the apply.sh post-install heredoc as unconditionally telling users to 'add a status-checks rule' even on the clud-bug-logmind variant, where that rule is already shipped. Same wording lives in README's 'After install' step 1. Worst-case failure: user manually edits the rule via the UI and clobbers the four shipped contexts. Also expands README step 3 to surface the variant's most important caveat: clud-bug AND logmind workflows must both be installed on the target repo, or the shipped required_status_checks rule blocks every PR forever (strict mode is on). Adds a README note tying strict-mode rationale to logmind v0.2's derived-file model so a future major-version bump triggers a re-review.

**Alternatives considered:** Fix only the apply.sh heredoc, leave README parallel passages alone — leaves the readme-vs-cli contradiction surfaced by Clud Bug only half-fixed, Rename the variant (canonical / thrillmot / full per design question 2a) — rejected; the explicit name doesn't overpromise and is future-proof, Drop check-links from the canonical context list (2b) — rejected; flakiness is anecdotal, Add _comment top-level field to the JSON instead of a README footnote (2c) — rejected as risky; GitHub rulesets API may reject unknown fields, README is more discoverable anyway, Redesign variants as flags --with-clud-bug --with-logmind (2d) — rejected; premature for three variants

**Implications:**
- PR #8 grows by ~30 lines of bash branching + ~20 lines of README + a strict-mode note. CLI surface unchanged (still 3 variants). Variant naming, four-context list, and CLI shape kept as-shipped.

---

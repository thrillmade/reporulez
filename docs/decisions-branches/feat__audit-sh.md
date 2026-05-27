## 2026-05-27 15:43 - feat: bin/audit.sh — read-only drift detector for canonical repo settings

**Reasoning:** First real run of the audit on thrillmade caught 4 repos with drift: raw-data (never apply.sh'd), .github (the profile repo, never apply.sh'd), rezgen (drifted post-migration despite my earlier one-off delete_branch_on_merge PATCH), tokenomics (allow_auto_merge: false, possibly intentional user flip)

**Alternatives considered:** Auto-fix mode (--fix flag that re-applies) — rejected; would clobber any per-repo customizations. The audit + manual remediation via apply.sh is the right split

**Implications:**
- Could ship a weekly scheduled workflow that runs audit.sh --all thrillmade and opens an issue on drift. Out of scope for v1 of audit.sh; one-line follow-up if useful

---
## 2026-05-27 16:09 - audit.sh: drift informational by default + --strict for CI gate + --quiet + arg-parser fix

**Reasoning:** Arg-parser bug caught while testing: --all --quiet thrillmade silently swallowed --quiet as the owner name. Added a guard rejecting flag-starting values for --all's owner arg

**Implications:**
- Output format is now intentionally honest — 'ℹ drift detected, INFORMATIONAL' rather than 'EVERYTHING IS BROKEN'. Future v0.4.1 of audit could add a .reporulez/audit.yml per-repo override file if the bench of intentional drifts grows

---
## 2026-05-27 16:13 - doc: swap --all flag order in README examples (clud-bug review)

**Reasoning:** Fix: swap to 'audit.sh --all thrillmade --quiet' — flag-after-owner. Now consistent with the guard's actual contract

**Implications:**
- Pattern note: when adding an arg-parser guard, grep the README + tests for the rejected form before shipping

---

## 2026-05-27 15:43 - feat: bin/audit.sh — read-only drift detector for canonical repo settings

**Reasoning:** First real run of the audit on thrillmade caught 4 repos with drift: raw-data (never apply.sh'd), .github (the profile repo, never apply.sh'd), rezgen (drifted post-migration despite my earlier one-off delete_branch_on_merge PATCH), tokenomics (allow_auto_merge: false, possibly intentional user flip)

**Alternatives considered:** Auto-fix mode (--fix flag that re-applies) — rejected; would clobber any per-repo customizations. The audit + manual remediation via apply.sh is the right split

**Implications:**
- Could ship a weekly scheduled workflow that runs audit.sh --all thrillmade and opens an issue on drift. Out of scope for v1 of audit.sh; one-line follow-up if useful

---

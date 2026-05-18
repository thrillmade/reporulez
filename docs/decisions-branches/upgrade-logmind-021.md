## 2026-05-18 13:36 - Upgrade logmind 0.2.0 → 0.2.1

**Reasoning:** Pick up 0.2.1's idempotent logmind init. Verified end-to-end: the refresh mode no longer bails on existing docs/ (fix to audit P1). The auto-pin __LOGMIND_VERSION__ substitution did NOT kick in on existing workflows — 0.2.1 reported 'all templates already current' even though the pip install line still read logmind==0.2.0. Likely 0.2.1 detects currency via the new template-version marker (which our workflows predate), so 'no marker = current' rather than 'no marker = stale.' Worth flagging upstream so audit P0 (auto-pinning) actually works for repos that upgrade through 0.2.1.

**Alternatives considered:** Wait for 0.2.2 with the auto-pin detection fixed — keeps us on 0.2.0 longer than necessary, Hand-write the template-version marker before running init to force the refresh — fragile, depends on knowing the marker syntax

**Implications:**
- Workflow pip-install lines manually sed'd from 0.2.0 to 0.2.1 since init didn't auto-substitute. Our standing customizations (actions/checkout@v6 across all three logmind workflows, check-doc-links path-filter removal) survive — init reported workflows current and did not rewrite them. README gains a new 'Upgrading tooling installed in the repo' section documenting the upgrade pattern for both clud-bug and logmind (logmind init is now idempotent in v0.2.1+; clud-bug has its own update flow).

---

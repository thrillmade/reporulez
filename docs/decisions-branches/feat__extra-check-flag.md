## 2026-05-18 14:15 - apply.sh: add --extra-check flag for project-specific contexts

**Reasoning:** Variants ship canonical required_status_checks but can't express project-specific contexts (e.g. pytest matrix) — variants don't know your CI workflow names. Without this flag, users hand-edit the live ruleset after apply.sh runs, which drifts on every re-apply. --extra-check 'CONTEXT NAME' (repeatable) appends contexts to the variant's required_status_checks via jq + unique_by(.context). Errors cleanly when used against variants that don't ship required_status_checks (copilot, external).

**Alternatives considered:** Bake project contexts into each variant — would couple reporulez to specific projects' CI, Skip and require manual UI edit forever — what we had; drifts on every re-apply, Switch apply.sh from PUT to PATCH semantics — GitHub rulesets API doesn't support PATCH on rules array; would require fetching then merging client-side, much more complex than the flag

**Implications:**
- Single apply.sh call now applies the full ruleset for a project; no manual UI step needed
- Idempotent: re-running with the same --extra-check flags produces the same ruleset (unique_by drops duplicates)
- Variants stay generic; project-specific knowledge lives at the apply call site

---

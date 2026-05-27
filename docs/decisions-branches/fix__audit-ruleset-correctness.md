## 2026-05-27 16:43 - fix(audit.sh): explicit includes_parents=true + loud-fail on per-ruleset GET + simplified drift propagation

**Reasoning:** (3+4) Trimmed the over-claiming word-boundary grep comment + simplified DRIFT_FOUND propagation by making audit_ruleset set the global directly (matches the settings-audit pattern); removed the prev_drift dead code in audit_one

---

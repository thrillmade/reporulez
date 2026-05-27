## 2026-05-27 16:35 - feat(audit.sh): --include-ruleset flag for ruleset structural drift

**Reasoning:** Variant-specific config (required_status_checks contents, bypass_actors content, copilot_code_review) intentionally NOT checked — would need to detect variant to assert correctly, and detection from existing ruleset is unreliable. The structural minimums are universal and check generically

**Alternatives considered:** Default-ON instead of opt-in — rejected; extra API calls per repo on --all <owner> add up, and the bot's recommendation was explicit on opt-in via flag

**Implications:**
- Also documents the personal-account limitation (orgs/<owner>/repos returns 404 on user accounts)

---

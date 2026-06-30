← back to [docs/timeline.md](../timeline.md)

## 2026-06-29 22:02 - rename reporulez variant clud-bug-logmind -> skdd (the canonical SkDD-toolchain ruleset)

**Reasoning:** The variant is the canonical SkDD-toolchain ruleset (protocol SPEC §7), not specific to clud-bug+logmind — it applies to any thrillmade SkDD repo (clud-bug/logmind/protocol). Renamed clud-bug-logmind.json -> skdd.json + all apply.sh/README references; kept clud-bug-logmind as a deprecated alias so existing callers keep working. Content unchanged (already the decided model: 0 approvals, the 4 canonical checks, admin bypass for self-mod).

**Implications:**
- Spec reconciliation follows: modernize protocol canonical-v1.json from classic branch-protection to the rulesets format to match

---


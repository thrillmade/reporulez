← back to [docs/timeline.md](../timeline.md)

## 2026-07-03 22:15 - reporulez: purpose-named ruleset taxonomy — drop copilot, external→baseline, +clud-bug +public-guard

**Reasoning:** The variant set was purpose-coupled + confusingly named. Renamed to a clean security taxonomy: baseline (structural floor, any repo) · clud-bug (baseline + clud-bug-review check) · skdd (full toolchain) · public-guard (baseline + human code-owner approval for public repos w/ outside contributors). Deleted copilot (wires GitHub's competing reviewer — CEO directive). public-guard encodes the trust boundary that an agent's review CHECK is advisory and NEVER substitutes for a human approval on an outsider PR. external kept as deprecated alias→baseline; default variant copilot→baseline.

**Alternatives considered:** keep copilot; combine check+approval into one variant

**Implications:**
- clud-bug configure-github will consume these as --preset {baseline,clud-bug,skdd,public-guard}; org-level rulesets (Phase Y) derive from the same JSON; agentic variant (scoped bot Integration bypass) planned, needs net-new plumbing

---


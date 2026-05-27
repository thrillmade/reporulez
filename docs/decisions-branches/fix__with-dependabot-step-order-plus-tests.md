## 2026-05-27 11:57 - fix(apply.sh + test.yml): reorder PUT-before-ruleset + consolidate traps + add YAML template validation

**Reasoning:** (A.11) Two separate 'trap rm -f' statements: the second silently shadowed the first. Replaced with a single trap calling 'cleanup()' that rm -fs every entry in CLEANUP_FILES. Each step appends its temp files to the array — adding a fourth temp file in the future is now safe without trap edits

**Implications:**
- Test plan in PR body specifies the copilot/external smoke that PR #21 missed

---
## 2026-05-27 12:04 - doc: trim re-apply rationale + document ecosystem-switch limitation (clud-bug review)

**Reasoning:** Fix: trim the misleading parenthetical + add a KNOWN LIMITATION block to the rationale comment + document the workaround in the README's dependabot-templates section

**Alternatives considered:** Genuinely cover the case (temp bypass_actors patch around the PUT) — rejected per bot's own suggestion as out-of-scope for this PR; the limited workflow is uncommon (most repos pin one ecosystem)

**Implications:**
- First-apply and idempotent-re-apply still work cleanly across all variants without intervention — the limitation is narrow and documented

---

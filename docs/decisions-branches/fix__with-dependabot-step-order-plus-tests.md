## 2026-05-27 11:57 - fix(apply.sh + test.yml): reorder PUT-before-ruleset + consolidate traps + add YAML template validation

**Reasoning:** (A.11) Two separate 'trap rm -f' statements: the second silently shadowed the first. Replaced with a single trap calling 'cleanup()' that rm -fs every entry in CLEANUP_FILES. Each step appends its temp files to the array — adding a fourth temp file in the future is now safe without trap edits

**Implications:**
- Test plan in PR body specifies the copilot/external smoke that PR #21 missed

---

## 2026-05-27 07:30 - feat(apply.sh): --with-dependabot=<eco> flag — write dependabot.yml at apply time

**Reasoning:** Validation against the 3-element whitelist (python/typescript/github-actions-only) happens BEFORE any network call, so a typo fails fast instead of after the ruleset PATCH lands and only the file-write step explodes

**Alternatives considered:** (a) refuse on existing-different — rejected per agent's note: silent overwrite matches --extra-check's overwrite-on-re-apply semantics, (b) ship --without-dependabot removal path — explicitly out-of-scope per agent's brief; rm in target repo is the supported removal path

**Implications:**
- Two arg forms supported: --with-dependabot python AND --with-dependabot=python (mirrors --extra-check pattern)
- Help block now spans lines 2-44 (was 2-35); usage() updated to match

---

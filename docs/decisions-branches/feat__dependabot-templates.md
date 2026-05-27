## 2026-05-27 00:26 - Ship per-ecosystem dependabot templates; dogfood github-actions-only on reporulez

**Reasoning:** reporulez is the canonical home for thrillmade-org repo-config templates (CODEOWNERS, pull_request_template.md already there). Dependabot config is org-wide boilerplate of the same shape — agents installing reporulez should be able to curl one file and have weekly bumps wired up. Three variants (python, typescript, github-actions-only) cover the realistic deployment targets; cadence/limits/labels modeled on thrillmade/logmind's existing dependabot.yml so thrillmade repos stay consistent. Adding .github/dependabot.yml to reporulez itself dogfoods the github-actions-only variant and proves the link between source-of-truth template and consumer copy.

**Alternatives considered:** Single auto-detecting template with a runtime/tool layer — rejected, static drop-ins are simpler and don't introduce a new tool surface., Docs-only example snippet in README — rejected, full files are easier for agents to copy mechanically and to version centrally., Ship bin/apply.sh --with-dependabot=<ecosystem> flag now — deferred per user's 'optional later' tag; manual curl is fine for one-time setup.

**Implications:**
- Cadence/limit changes happen in one place (templates/dependabot/*.yml); consumers re-curl to refresh. If thrillmade/logmind's dependabot.yml drifts, templates/dependabot/python.yml becomes the source of truth going forward.
- AGENTS.md logmind-block refresh (v4-slim → current) and --with-dependabot flag both intentionally out of scope; queued as follow-up PRs to keep this one focused on the templates surface.

---

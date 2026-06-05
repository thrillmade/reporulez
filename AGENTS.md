# AGENTS.md

This is the canonical instruction file for AI coding agents working in this
repository. Tools that understand `AGENTS.md` (Cursor, Codex, Windsurf,
Claude Code, Cline, Continue, Aider, ...) read this file directly. Per-tool
files like `CLAUDE.md` or `.cursorrules` are stubs that point here so the
guidance lives in one place.

<!-- logmind-start -->
<!-- logmind-block-version: v7-pointer -->
## Decision logging — `logmind log` is the commit primitive

**`logmind log` replaces `git add` + `git commit` + `git push` for any change that carries a decision** — do not run those git commands directly.

```bash
logmind log "summary" -r "why" -a "alternative" -i "implication"
```

This project uses [logmind](https://logmind.dev). What counts as a decision, branch routing, `--stage scoped` for unrelated WIP, `logmind doctor`, and the required-reading list ([`docs/timeline.md`](docs/timeline.md), [`docs/decisions.md`](docs/decisions.md), [`docs/file-structure.md`](docs/file-structure.md), `docs/decisions-branches/<branch>.md`) all live in the **`logmind` agent skill** at https://github.com/thrillmade/agent-skills/tree/main/skills/logmind.
<!-- logmind-end -->

## Project Overview

`reporulez` ships opinionated GitHub **repository rulesets** for AI-driven
development. The installer (`bin/apply.sh`) tunes target-repo settings
(auto-merge, squash-only, delete-on-merge) and POSTs a ruleset that requires
PRs, blocks force pushes and default-branch deletions, enforces thread
resolution, and (in the `copilot` variant) wires up GitHub Copilot
auto-review. Two variants — `copilot` and `external` — plus a
`--human-review` flag. See `README.md` for the full design.

This repo itself uses the `external` variant: clud-bug is the AI reviewer (now
delivered via the `clud-bug[bot]` GitHub App installed at the thrillmade org
— no per-repo workflow), logmind enforces decision logging, and CI gates every
PR on `check-decisions` and `check-links` (all currently passing).

## Development Commands

```bash
# Validate ruleset JSON
jq . rulesets/*.json

# Syntax-check the installer
bash -n bin/apply.sh

# Apply rulesets to a target repo (dogfood / end-to-end test)
./bin/apply.sh <owner/repo> [copilot|external] [--human-review]
```

There is no test suite. End-to-end validation is "apply against a throwaway
repo and inspect via the GitHub UI / API."

## Contributor Setup

After cloning, contributors should:

1. **Install logmind** locally (CLI tool used to log decisions):
   ```bash
   brew install thrillmade/tap/logmind   # macOS + Linux; or: curl -fsSL https://logmind.dev/install.sh | bash
   logmind install-hook   # .git/hooks/pre-commit
   ```
   The same enforcement runs on every PR via `.github/workflows/check-decisions.yml`
   (shipped by logmind itself), so skipping the local hook only delays the failure —
   it still blocks merge.

2. **When CI flags `docs/timeline.md` as stale,** regenerate it locally and push:
   ```bash
   logmind timeline --write docs/timeline.md
   git add docs/timeline.md
   git commit -m "regen: docs/timeline.md"
   git push
   ```
   `docs/timeline.md` is a derived file — auto-regenerated chronological overview
   across all branches. The `check-derived-docs` workflow (`.github/workflows/regen-timeline.yml`)
   fails fast when it's stale. Running `logmind timeline --write` locally before
   pushing avoids the red CI run.

<!-- clud-bug-start -->
<!-- clud-bug-block-version: v3-app -->
## clud-bug — Claude PR review

**PR reviews:** automated via the `clud-bug[bot]` GitHub App (installed at the thrillmade org). No per-repo workflow needed. See <https://github.com/thrillmade/clud-bug-app> for the App source and the `.claude/skills/.clud-bug.json` manifest for skill selection.

Collaboration rules — fix-push flow, skill structure, comment format — live in the bundled [`clud-bug-collaboration` skill](.claude/skills/clud-bug-collaboration/SKILL.md). Read that skill before pushing fixes addressing prior review threads.

For agent invocations of the `clud-bug` CLI, prefer `CLUD_BUG_QUIET=1` (or pass `--quiet`) — suppresses progress chatter and emits a single `ok <key-value>` summary line per command.
<!-- clud-bug-end -->

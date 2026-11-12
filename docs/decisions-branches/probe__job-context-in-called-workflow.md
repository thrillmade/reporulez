← back to [docs/timeline.md](../timeline.md)

## 2026-11-12 01:58 - Probe (never merged): check at runtime whether job.workflow_repository and job.workflow_sha resolve inside a called workflow

**Reasoning:** Two open pull requests make their reusable workflows check out their own source with those values, as GitHub documents; a local linter does not know them yet, and a wrong value would run scripts from the wrong commit with a caller's token.

**Alternatives considered:** Trust the documentation: rejected, the cost of being wrong is a write-scoped token running unintended code. Prove it on first real use: rejected, that is after merge.

**Implications:**
- This branch exists only to produce one workflow run and is closed without merging.

---


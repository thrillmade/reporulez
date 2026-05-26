## 2026-05-26 17:49 - Reinit clud-bug install at v0.5.15 (recovery from pre-marker install)

**Reasoning:** This repos clud-bug install predated v0.5.6 (when template version markers shipped) and v0.5.7 marker-driven refresh-mode. The existing workflow at .github/workflows/clud-bug-review.yml had NO clud-bug-template-version marker, so refresh-mode (npx clud-bug update) would have treated it as user-customized and skipped it. Per the documented recovery path in v0.5.7 CHANGELOG: delete the markerless files + run clud-bug init from scratch. After this PR: workflow is at v9 templates, composite ref @v0.5.15, claude-code-action @v1.0.133 pinned, 4 baseline skills installed (added clud-bug-collaboration which shipped in v0.5.1), audit + self-update workflows installed, manifest stamped with strictMode: true.

**Alternatives considered:** Wait for the weekly self-update cron Mondays 12:00 UTC to drift this repo forward through every clud-bug release one PR at a time. Rejected: the cron requires the install ALREADY have logmind-self-update.yml + a marker-bearing workflow it can refresh from. Pre-v0.5.6 markerless installs cannot be refreshed at all by the cron; manual recovery is the only path.

**Implications:**
- Everything that shipped in clud-bug v0.5.7-v0.5.15 is now active on reporulez: refresh-mode, composite strict-mode gate, BB.3 per-skill check-runs, inline review threads (the entire required_review_thread_resolution gate the variant already had configured), sort fix for newest-first comment selection, composite-pin lock-step rule. Future clud-bug releases pick up automatically via the now-installed self-update workflow.

---

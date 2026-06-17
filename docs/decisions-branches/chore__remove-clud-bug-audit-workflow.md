← back to [docs/timeline.md](../timeline.md)

## 2026-06-17 11:20 - Remove clud-bug-audit.yml workflow to stop ANTHROPIC_API_KEY billing from dogfood audits

**Reasoning:** Phase 5.3 paused App-side dogfooding on rebuild repos but the cron-scheduled audit workflow ran independently using the direct API key, generating per-cron billing on every run. Re-enable via hosted App audit path post-launch.

**Alternatives considered:** Keep workflow but disable schedule, Conditional run based on actor

**Implications:**
- Audit feature comes back via App webhook + Vercel AI Gateway after Marketplace launch

---


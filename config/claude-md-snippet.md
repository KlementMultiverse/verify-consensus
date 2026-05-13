<!-- INSTALL: Add this section to your ~/.claude/CLAUDE.md -->

## Verification Policy (MANDATORY — every query)

**Every query must go through verify-consensus.** No exceptions.

1. ALWAYS write `.claude/verify-state.json` as your FIRST action.
2. Classify: trivial | standard | research.
3. Trivial -> mark `"trivial": true` in state -> answer directly.
4. Standard -> run Codex review (max 6 rounds).
5. Research -> run Codex adversarial review with extended thinking (max 6 rounds).
6. The Stop hook WILL BLOCK you from finishing without this.

### Agreement rule
Two consecutive rounds of agreement required (Aegean stability).

### Citation enforcement
Every factual claim must have a fetched URL with a supporting quote.

### Escape hatches (user-controlled, NOT for Claude to self-invoke)
- `CLAUDE_SKIP_VERIFY=1` env var (session)
- `touch ~/.claude/verify-skip-global` (global kill switch)
- `touch .claude/verify-skip` (project-level)
- Remove the file to re-enable.

### Observability
- Per-iteration logs: `~/.claude/logs/verify-iterations.jsonl`
- Session summaries: `~/.claude/logs/verify-sessions.jsonl`
- Gate decisions: `~/.claude/logs/verify-gate.jsonl`
- Project-local: `.claude/verify-log.jsonl`

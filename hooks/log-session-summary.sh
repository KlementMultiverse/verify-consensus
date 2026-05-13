#!/usr/bin/env bash
# ============================================================
# LOGGING: Session summary — runs on Stop hook
# ============================================================
# PURPOSE: Reads .claude/verify-state.json and writes a session
#          summary to the global sessions log. Cleans up state
#          file after logging.
#
# INSTALL: Copy to ~/.claude/hooks/log-session-summary.sh
#          Add to ~/.claude/settings.json under hooks.Stop
#          (AFTER stop-verify-gate.sh in the array)
#
# DEPENDENCIES: jq
# ============================================================

GLOBAL_LOG="$HOME/.claude/logs/verify-sessions.jsonl"
mkdir -p "$HOME/.claude/logs"

STATE=".claude/verify-state.json"

if [[ ! -f "$STATE" ]]; then
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cwd\":\"$(pwd)\",\"verified\":false,\"reason\":\"no-state-file\"}" >> "$GLOBAL_LOG"
  exit 0
fi

SUMMARY=$(jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" '{
  ts: $ts,
  cwd: $cwd,
  verified: true,
  trivial: (.trivial // false),
  question: (.question // "unknown"),
  complexity: (.complexity // "unknown"),
  iterations: (.iteration // 0),
  final_agreed: (if .history | length >= 2 then
    (.history | reverse | [limit(2; .[])] | map(.agreed) | all)
  else false end),
  history_length: (.history | length),
  outcome: (.outcome // "incomplete")
}' "$STATE" 2>/dev/null)

if [[ -n "$SUMMARY" && "$SUMMARY" != "null" ]]; then
  echo "$SUMMARY" >> "$GLOBAL_LOG"
else
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cwd\":\"$(pwd)\",\"verified\":true,\"parse_error\":true}" >> "$GLOBAL_LOG"
fi

rm -f "$STATE"

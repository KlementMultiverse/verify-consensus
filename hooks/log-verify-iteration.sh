#!/usr/bin/env bash
# ============================================================
# LOGGING: Append verification iteration to JSONL logs
# ============================================================
# PURPOSE: Records each verification iteration for observability.
#          Called by the verify-consensus skill (not a hook itself).
#
# INSTALL: Copy to ~/.claude/hooks/log-verify-iteration.sh
#
# USAGE:   bash ~/.claude/hooks/log-verify-iteration.sh '<json_payload>'
#          echo '<json>' | bash ~/.claude/hooks/log-verify-iteration.sh
#
# LOGS TO:
#   1. ~/.claude/logs/verify-iterations.jsonl  (global)
#   2. .claude/verify-log.jsonl                (project-local)
#
# DEPENDENCIES: jq
# ============================================================

GLOBAL_LOG="$HOME/.claude/logs/verify-iterations.jsonl"
LOCAL_LOG=".claude/verify-log.jsonl"

mkdir -p "$HOME/.claude/logs"
mkdir -p "$(dirname "$LOCAL_LOG")"

PAYLOAD="$1"
if [[ -z "$PAYLOAD" ]]; then
  PAYLOAD=$(cat)
fi

ENRICHED=$(echo "$PAYLOAD" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" \
  '. + {ts: (.ts // $ts), cwd: (.cwd // $cwd)}' 2>/dev/null)

if [[ -z "$ENRICHED" || "$ENRICHED" == "null" ]]; then
  ENRICHED="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cwd\":\"$(pwd)\",\"raw\":\"$PAYLOAD\"}"
fi

echo "$ENRICHED" >> "$GLOBAL_LOG"
echo "$ENRICHED" >> "$LOCAL_LOG"

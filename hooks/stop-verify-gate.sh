#!/usr/bin/env bash
# ============================================================
# STOP HOOK: Verification Gate
# ============================================================
# PURPOSE: Blocks Claude Code from finishing ANY task unless
#          verification is complete or an escape hatch is active.
#
# INSTALL: Copy to ~/.claude/hooks/stop-verify-gate.sh
#          Then add to ~/.claude/settings.json under hooks.Stop
#
# EXIT CODES:
#   0 = allow stop
#   2 = block stop (Claude Code convention)
#
# ESCAPE HATCHES (checked in order):
#   1. CLAUDE_SKIP_VERIFY=1 env var (session-level)
#   2. ~/.claude/verify-skip-global file exists (global kill switch)
#   3. .claude/verify-skip file in project (project-level)
#   4. State file has "trivial": true
#   5. iteration >= 6 (cap reached)
#   6. 2 consecutive agreements in history (Aegean stability)
#
# DEPENDENCIES: jq
# ============================================================

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/verify-gate.jsonl"
mkdir -p "$LOG_DIR"

log_event() {
  local action="$1" reason="$2"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"$action\",\"reason\":\"$reason\",\"cwd\":\"$(pwd)\"}" >> "$LOG_FILE"
}

# --- Escape hatch 1: env var ---
if [[ "${CLAUDE_SKIP_VERIFY:-0}" == "1" ]]; then
  log_event "allow" "env:CLAUDE_SKIP_VERIFY=1"
  exit 0
fi

# --- Escape hatch 2: global kill switch ---
if [[ -f "$HOME/.claude/verify-skip-global" ]]; then
  log_event "allow" "file:verify-skip-global"
  exit 0
fi

# --- Escape hatch 3: project-level skip ---
if [[ -f ".claude/verify-skip" ]]; then
  log_event "allow" "file:project-verify-skip"
  exit 0
fi

# --- Check state file ---
STATE=".claude/verify-state.json"

if [[ ! -f "$STATE" ]]; then
  log_event "block" "no-state-file"
  echo "BLOCK: No verification state found. Run verify-consensus or classify this task. Escape: touch .claude/verify-skip" >&2
  exit 2
fi

# --- Escape hatch 4: trivial classification ---
trivial=$(jq -r '.trivial // false' "$STATE" 2>/dev/null)
if [[ "$trivial" == "true" ]]; then
  log_event "allow" "classified:trivial"
  exit 0
fi

# --- Check iteration cap ---
iter=$(jq -r '.iteration // 0' "$STATE" 2>/dev/null)
if [[ "$iter" -ge 6 ]]; then
  log_event "allow" "iteration-cap:$iter"
  exit 0
fi

# --- Check 2 consecutive agreements (Aegean stability) ---
history_len=$(jq -r '.history | length' "$STATE" 2>/dev/null)
if [[ "$history_len" -ge 2 ]]; then
  last_two_agreed=$(jq -r '
    .history | reverse | [limit(2; .[])] |
    map(.agreed) | all
  ' "$STATE" 2>/dev/null)

  if [[ "$last_two_agreed" == "true" ]]; then
    log_event "allow" "aegean-stable:iter=$iter"
    exit 0
  fi
fi

# --- Block: verification not complete ---
log_event "block" "incomplete:iter=$iter,history=$history_len"
echo "BLOCK: Verification incomplete. iteration=$iter, need 2 consecutive agreements or 6 rounds." >&2
echo "Escape hatches: CLAUDE_SKIP_VERIFY=1 | touch .claude/verify-skip | classify as trivial" >&2
exit 2

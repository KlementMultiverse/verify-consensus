#!/usr/bin/env bash
# ============================================================
# STOP HOOK: Verification Gate (v2 — structural enforcement)
# ============================================================
# PURPOSE: Blocks Claude Code from finishing ANY task unless
#          verification is complete or an escape hatch is active.
#
#          v2 adds STRUCTURAL ENFORCEMENT: the hook cross-checks
#          that Codex was actually called by verifying:
#          1. Iteration log entries exist matching state claims
#          2. Each iteration has a codex_response_hash (proof of Codex call)
#          3. Non-trivial tasks MUST have at least 1 verified iteration
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
#
# VERIFICATION CHECKS (for non-trivial):
#   4. State file exists with classification
#   5. If trivial=true → allow
#   6. Iteration log has entries with codex_response_hash (proof-of-work)
#   7. Log entry count matches state iteration count
#   8. iteration >= 6 OR 2 consecutive agreements (Aegean stability)
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
LOCAL_LOG=".claude/verify-log.jsonl"

if [[ ! -f "$STATE" ]]; then
  log_event "block" "no-state-file"
  echo "BLOCK: No verification state found. Run verify-consensus or classify this task." >&2
  echo "Escape: touch .claude/verify-skip" >&2
  exit 2
fi

# --- Trivial classification ---
trivial=$(jq -r '.trivial // false' "$STATE" 2>/dev/null)
if [[ "$trivial" == "true" ]]; then
  log_event "allow" "classified:trivial"
  exit 0
fi

# ============================================================
# STRUCTURAL ENFORCEMENT (non-trivial tasks only)
# ============================================================

# --- Check 1: iteration log must exist ---
if [[ ! -f "$LOCAL_LOG" ]]; then
  log_event "block" "no-iteration-log"
  echo "BLOCK: No iteration log found (.claude/verify-log.jsonl). Codex was never called." >&2
  echo "Non-trivial tasks MUST run Codex verification." >&2
  exit 2
fi

# --- Check 2: count iteration entries with codex_response_hash ---
# Only entries with event="iteration" AND a non-null codex_response_hash count
verified_iterations=$(jq -s '[.[] | select(.event == "iteration" and .codex_response_hash != null and .codex_response_hash != "")] | length' "$LOCAL_LOG" 2>/dev/null)
verified_iterations=${verified_iterations:-0}

if [[ "$verified_iterations" -eq 0 ]]; then
  log_event "block" "no-codex-proof"
  echo "BLOCK: No iteration entries with codex_response_hash found. Codex was never called." >&2
  echo "Each iteration must include a hash of the Codex response as proof-of-work." >&2
  exit 2
fi

# --- Check 3: state iteration count must match log entries ---
state_iter=$(jq -r '.iteration // 0' "$STATE" 2>/dev/null)
total_log_iterations=$(jq -s '[.[] | select(.event == "iteration")] | length' "$LOCAL_LOG" 2>/dev/null)
total_log_iterations=${total_log_iterations:-0}

if [[ "$state_iter" -gt 0 && "$total_log_iterations" -lt "$state_iter" ]]; then
  log_event "block" "iteration-mismatch:state=$state_iter,log=$total_log_iterations"
  echo "BLOCK: State claims $state_iter iterations but log only has $total_log_iterations entries." >&2
  exit 2
fi

# --- Check 4: iteration cap ---
if [[ "$state_iter" -ge 6 ]]; then
  log_event "allow" "iteration-cap:$state_iter,verified=$verified_iterations"
  exit 0
fi

# --- Check 5: 2 consecutive agreements (Aegean stability) ---
history_len=$(jq -r '.history | length' "$STATE" 2>/dev/null)
if [[ "$history_len" -ge 2 ]]; then
  last_two_agreed=$(jq -r '
    .history | reverse | [limit(2; .[])] |
    map(.agreed) | all
  ' "$STATE" 2>/dev/null)

  if [[ "$last_two_agreed" == "true" ]]; then
    # Cross-check: the last 2 log entries must also show agreed=true
    log_last_two_agreed=$(jq -s '
      [.[] | select(.event == "iteration")] | reverse | [limit(2; .[])] |
      map(.agreed) | all
    ' "$LOCAL_LOG" 2>/dev/null)

    if [[ "$log_last_two_agreed" == "true" ]]; then
      log_event "allow" "aegean-stable:iter=$state_iter,verified=$verified_iterations"
      exit 0
    else
      log_event "block" "aegean-mismatch:state-says-agreed,log-disagrees"
      echo "BLOCK: State claims 2 consecutive agreements but iteration log disagrees." >&2
      exit 2
    fi
  fi
fi

# --- Block: verification not complete ---
log_event "block" "incomplete:iter=$state_iter,verified=$verified_iterations,history=$history_len"
echo "BLOCK: Verification incomplete. iteration=$state_iter, verified=$verified_iterations." >&2
echo "Need 2 consecutive agreements or 6 rounds with Codex proof-of-work." >&2
exit 2

#!/usr/bin/env bash
# ============================================================
# STOP HOOK: Verification Gate (v3 — phase-aware enforcement)
# ============================================================
# PURPOSE: Blocks Claude Code from finishing ANY task unless
#          verification is complete or an escape hatch is active.
#
# PHASES (non-trivial tasks):
#   classifying  — Claude showed classification, waiting for user
#   researching  — gathering citations, user reviewing sources
#   iterating    — Codex loop in progress, mid-round
#   complete     — loop done (2 agreements or 6 rounds)
#
#   Temporary phases (classifying/researching/iterating) allow
#   Claude to pause for user interaction mid-flow. But the ACTUAL
#   answer cannot be delivered until phase=complete with full
#   proof-of-work.
#
# INSTALL: Copy to ~/.claude/hooks/stop-verify-gate.sh
#          Then add to ~/.claude/settings.json under hooks.Stop
#
# EXIT CODES:
#   0 = allow stop
#   2 = block stop (Claude Code convention)
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

# ============================================================
# CLASSIFICATION VALIDATION
# ============================================================
# Every query MUST have a valid complexity. Reject unknown values.

complexity=$(jq -r '.complexity // ""' "$STATE" 2>/dev/null)
trivial=$(jq -r '.trivial // false' "$STATE" 2>/dev/null)

# --- Validate complexity is a known value ---
case "$complexity" in
  trivial|standard|research) ;;  # valid
  *)
    log_event "block" "invalid-complexity:$complexity"
    echo "BLOCK: Invalid complexity '$complexity'. Must be trivial, standard, or research." >&2
    exit 2
    ;;
esac

# --- Validate trivial flag matches complexity ---
if [[ "$complexity" == "trivial" && "$trivial" != "true" ]]; then
  log_event "block" "complexity-trivial-mismatch:complexity=trivial,trivial=$trivial"
  echo "BLOCK: complexity=trivial but trivial flag is not true. Inconsistent state." >&2
  exit 2
fi
if [[ "$complexity" != "trivial" && "$trivial" == "true" ]]; then
  log_event "block" "complexity-trivial-mismatch:complexity=$complexity,trivial=true"
  echo "BLOCK: complexity=$complexity but trivial=true. Cannot mark non-trivial as trivial." >&2
  exit 2
fi

# --- Trivial: allow ---
if [[ "$trivial" == "true" ]]; then
  log_event "allow" "classified:trivial"
  exit 0
fi

# ============================================================
# PHASE VALIDATION + ENFORCEMENT (non-trivial tasks only)
# ============================================================

phase=$(jq -r '.phase // ""' "$STATE" 2>/dev/null)

# --- Validate phase is a known value ---
case "$phase" in
  classifying|researching|iterating|complete) ;;  # valid
  "")
    log_event "block" "missing-phase:complexity=$complexity"
    echo "BLOCK: Non-trivial task (complexity=$complexity) has no phase. Phase is required." >&2
    echo "Valid phases: classifying, researching, iterating, complete" >&2
    exit 2
    ;;
  *)
    log_event "block" "invalid-phase:$phase"
    echo "BLOCK: Invalid phase '$phase'. Must be classifying, researching, iterating, or complete." >&2
    exit 2
    ;;
esac

# --- Temporary phases: allow mid-flow stops ---
# These let Claude pause to show work to the user between steps.
# The actual answer CANNOT be delivered in these phases.
case "$phase" in
  classifying)
    log_event "allow" "phase:classifying"
    exit 0
    ;;
  researching)
    log_event "allow" "phase:researching"
    exit 0
    ;;
  iterating)
    # Allow mid-iteration stops ONLY if at least starting the loop
    # (iteration >= 1 means at least one round attempted)
    iter=$(jq -r '.iteration // 0' "$STATE" 2>/dev/null)
    if [[ "$iter" -ge 0 ]]; then
      log_event "allow" "phase:iterating,iter=$iter"
      exit 0
    fi
    ;;
esac

# --- Phase: complete — full structural verification required ---
# If phase=complete OR no phase set, we require full proof-of-work.

# --- Check 1: iteration log must exist ---
if [[ ! -f "$LOCAL_LOG" ]]; then
  log_event "block" "no-iteration-log"
  echo "BLOCK: No iteration log found (.claude/verify-log.jsonl). Codex was never called." >&2
  echo "Non-trivial tasks MUST run Codex verification. Set phase to classifying/researching/iterating if mid-flow." >&2
  exit 2
fi

# --- Check 2: count iteration entries with codex_response_hash ---
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
echo "Or set phase to classifying/researching/iterating if mid-flow." >&2
exit 2

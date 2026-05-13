#!/usr/bin/env bash
# ============================================================
# STOP HOOK: Verification Gate (v4 — work-first, review-after)
# ============================================================
# PURPOSE: Lightweight gate that ensures Claude classified every
#          query and ran verification for non-trivial work.
#
#          v4 CHANGE: Claude works freely first. Codex review
#          happens AFTER work is done via /verify command.
#          This hook just checks the state file is valid.
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

if [[ ! -f "$STATE" ]]; then
  log_event "block" "no-state-file"
  echo "BLOCK: No verification state found. Write .claude/verify-state.json with classification." >&2
  echo "RETRY: Classify as trivial | standard | research" >&2
  exit 2
fi

# --- Validate complexity ---
complexity=$(jq -r '.complexity // ""' "$STATE" 2>/dev/null)
trivial=$(jq -r '.trivial // false' "$STATE" 2>/dev/null)

case "$complexity" in
  trivial|standard|research) ;;
  *)
    log_event "block" "invalid-complexity:$complexity"
    echo "BLOCK: Invalid complexity '$complexity'." >&2
    echo "RETRY: Reclassify with exactly one of: trivial | standard | research" >&2
    exit 2
    ;;
esac

# --- Validate trivial consistency ---
if [[ "$complexity" == "trivial" && "$trivial" != "true" ]]; then
  log_event "block" "trivial-mismatch:complexity=trivial,trivial=$trivial"
  echo "BLOCK: complexity=trivial but trivial is not true." >&2
  echo "RETRY: Set trivial=true, or reclassify as: standard | research" >&2
  exit 2
fi
if [[ "$complexity" != "trivial" && "$trivial" == "true" ]]; then
  log_event "block" "trivial-mismatch:complexity=$complexity,trivial=true"
  echo "BLOCK: complexity=$complexity but trivial=true." >&2
  echo "RETRY: Set trivial=false, or reclassify as trivial (only if genuinely trivial)" >&2
  exit 2
fi

# --- Trivial: allow immediately ---
if [[ "$trivial" == "true" ]]; then
  log_event "allow" "classified:trivial"
  exit 0
fi

# ============================================================
# NON-TRIVIAL: Check that Codex review was run
# ============================================================

LOCAL_LOG=".claude/verify-log.jsonl"
status=$(jq -r '.status // ""' "$STATE" 2>/dev/null)

# --- Status: verified = review completed successfully ---
if [[ "$status" == "verified" ]]; then
  # Cross-check: log must have at least 1 iteration with codex hash
  if [[ -f "$LOCAL_LOG" ]]; then
    verified_count=$(jq -s '[.[] | select(.event == "iteration" and .codex_response_hash != null and .codex_response_hash != "")] | length' "$LOCAL_LOG" 2>/dev/null)
    verified_count=${verified_count:-0}
    if [[ "$verified_count" -ge 1 ]]; then
      log_event "allow" "verified:iterations=$verified_count"
      exit 0
    fi
  fi
  log_event "block" "status-verified-but-no-proof"
  echo "BLOCK: Status says verified but no Codex proof-of-work in log." >&2
  exit 2
fi

# --- Status: working = Claude is still working, allow ---
if [[ "$status" == "working" ]]; then
  log_event "allow" "status:working"
  exit 0
fi

# --- Status: reviewing = Codex review in progress, allow ---
if [[ "$status" == "reviewing" ]]; then
  log_event "allow" "status:reviewing"
  exit 0
fi

# --- Status: capped = 6 rounds without consensus, allow ---
if [[ "$status" == "capped" ]]; then
  if [[ -f "$LOCAL_LOG" ]]; then
    verified_count=$(jq -s '[.[] | select(.event == "iteration" and .codex_response_hash != null)] | length' "$LOCAL_LOG" 2>/dev/null)
    if [[ "${verified_count:-0}" -ge 6 ]]; then
      log_event "allow" "capped:iterations=$verified_count"
      exit 0
    fi
  fi
  log_event "block" "capped-but-insufficient-iterations"
  echo "BLOCK: Status says capped but fewer than 6 verified iterations in log." >&2
  exit 2
fi

# --- No status or unknown status ---
if [[ -z "$status" ]]; then
  log_event "block" "no-status"
  echo "BLOCK: Non-trivial task has no status. Claude must set status." >&2
  echo "RETRY: Set status to 'working' while working, then run /verify when done." >&2
  exit 2
fi

log_event "block" "unknown-status:$status"
echo "BLOCK: Unknown status '$status'." >&2
echo "RETRY: Valid statuses: working | reviewing | verified | capped" >&2
exit 2

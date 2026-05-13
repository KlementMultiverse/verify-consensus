#!/usr/bin/env bash
# ============================================================
# CODEX REVIEW RUNNER: Bridges context to Codex for any query
# ============================================================
# PURPOSE: Reads .claude/verify-context.md (written by Claude
#          before calling this) and sends it to Codex via the
#          companion script or MCP tool.
#
# USAGE:
#   Standard review:
#     bash ~/.claude/hooks/run-codex-review.sh standard
#
#   Adversarial research review:
#     bash ~/.claude/hooks/run-codex-review.sh research
#
# PREREQS:
#   Claude must write .claude/verify-context.md BEFORE calling
#   this script. The file should contain:
#   - ## Question (user's original question)
#   - ## Answer (Claude's full answer)
#   - ## Key Claims (numbered list)
#   - ## Citations (URLs with quotes)
#   - ## Context (any relevant background, file contents, etc.)
#
# INSTALL: Copy to ~/.claude/hooks/run-codex-review.sh
#
# DEPENDENCIES: codex CLI, jq
# ============================================================

set -euo pipefail

REVIEW_TYPE="${1:-standard}"
CONTEXT_FILE=".claude/verify-context.md"

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "ERROR: $CONTEXT_FILE not found. Claude must write context before calling review." >&2
  exit 1
fi

CONTEXT=$(cat "$CONTEXT_FILE")

if [[ "$REVIEW_TYPE" == "research" ]]; then
  PROMPT="You are an adversarial second reviewer. Your job is to challenge assumptions, find blind spots, and pressure-test the strategy.

$CONTEXT

TASK:
1. Produce your OWN complete competing answer (not just critique)
2. Challenge design choices, assumptions, and tradeoffs
3. Check cited facts against your knowledge
4. List ALL disagreements with severity (low/med/high)
5. If you substantially agree after review, state that clearly
Reasoning effort: high."
else
  PROMPT="You are reviewing an AI assistant's answer for accuracy and completeness.

$CONTEXT

TASK: Produce your own independent answer to the same question.
Compare with the AI's answer. List disagreements with severity (low/med/high).
If you substantially agree, say so."
fi

# Try codex CLI first, fall back to echo for manual use
if command -v codex &>/dev/null; then
  echo "$PROMPT" | codex --quiet --approval-mode full-auto 2>/dev/null
else
  echo "CODEX NOT AVAILABLE. Manual review prompt below:"
  echo "---"
  echo "$PROMPT"
fi

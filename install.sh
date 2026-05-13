#!/usr/bin/env bash
# ============================================================
# INSTALLER: verify-consensus for Claude Code
# ============================================================
# PURPOSE: Copies all files to the correct locations under ~/.claude/
#
# USAGE:   bash install.sh
#
# WHAT IT DOES:
#   1. Copies hook scripts to ~/.claude/hooks/
#   2. Copies skill to ~/.claude/skills/verify-consensus/
#   3. Creates log directories
#   4. Prints next steps (manual config needed)
#
# DEPENDENCIES: jq, node (for Codex CLI)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "=== verify-consensus installer ==="
echo ""

# Create directories
mkdir -p "$CLAUDE_DIR/hooks"
mkdir -p "$CLAUDE_DIR/skills/verify-consensus"
mkdir -p "$CLAUDE_DIR/logs"

# Copy hooks
echo "[1/3] Copying hook scripts..."
cp "$SCRIPT_DIR/hooks/stop-verify-gate.sh" "$CLAUDE_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/log-verify-iteration.sh" "$CLAUDE_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/log-session-summary.sh" "$CLAUDE_DIR/hooks/"
cp "$SCRIPT_DIR/hooks/rotate-logs.sh" "$CLAUDE_DIR/hooks/"
chmod +x "$CLAUDE_DIR/hooks/"*.sh

# Copy skill
echo "[2/3] Copying skill..."
cp "$SCRIPT_DIR/skills/verify-consensus/SKILL.md" "$CLAUDE_DIR/skills/verify-consensus/"

# Check dependencies
echo "[3/3] Checking dependencies..."
if ! command -v jq &>/dev/null; then
  echo "  WARNING: jq not found. Install it: sudo apt install jq"
fi
if ! command -v codex &>/dev/null; then
  echo "  WARNING: Codex CLI not found. Install it: npm install -g @openai/codex"
fi

echo ""
echo "=== Files installed ==="
echo ""
echo "NEXT STEPS (manual):"
echo ""
echo "1. Add hooks to ~/.claude/settings.json:"
echo "   See config/settings-hooks.json for the exact JSON to merge."
echo ""
echo "2. Add verification policy to ~/.claude/CLAUDE.md:"
echo "   See config/claude-md-snippet.md for the text to add."
echo ""
echo "3. Add MCP servers to ~/.claude.json:"
echo "   See config/mcp-servers-snippet.json for Codex + Context7 config."
echo ""
echo "4. Login to Codex: codex login"
echo ""
echo "Done! Start a new Claude Code session to activate."

#!/usr/bin/env bash
# ============================================================
# LOG ROTATION: Runs on SessionStart hook
# ============================================================
# PURPOSE: Prevents log files from growing unbounded.
#          Rotates files over 10MB, archives after 30 days,
#          deletes after 90 days.
#
# INSTALL: Copy to ~/.claude/hooks/rotate-logs.sh
#          Add to ~/.claude/settings.json under hooks.SessionStart
#
# ROTATION: file.jsonl -> file.jsonl.1 -> .2 -> .3 -> deleted
#
# DEPENDENCIES: None (uses standard coreutils)
# ============================================================

LOG_DIR="$HOME/.claude/logs"
ARCHIVE_DIR="$LOG_DIR/archive"
MAX_SIZE_BYTES=$((10 * 1024 * 1024))  # 10MB
MAX_ROTATIONS=3
RETENTION_DAYS=30

mkdir -p "$ARCHIVE_DIR"

rotate_file() {
  local file="$1"
  [[ ! -f "$file" ]] && return

  local size
  size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)

  if [[ "$size" -ge "$MAX_SIZE_BYTES" ]]; then
    for i in $(seq $((MAX_ROTATIONS - 1)) -1 1); do
      [[ -f "${file}.$i" ]] && mv "${file}.$i" "${file}.$((i + 1))"
    done
    [[ -f "${file}.$((MAX_ROTATIONS + 1))" ]] && rm -f "${file}.$((MAX_ROTATIONS + 1))"
    mv "$file" "${file}.1"
    touch "$file"
  fi
}

for logfile in "$LOG_DIR"/verify-gate.jsonl \
               "$LOG_DIR"/verify-iterations.jsonl \
               "$LOG_DIR"/verify-sessions.jsonl; do
  rotate_file "$logfile"
done

find "$LOG_DIR" -name "*.jsonl.[0-9]" -mtime +"$RETENTION_DAYS" -exec mv {} "$ARCHIVE_DIR/" \; 2>/dev/null
find "$ARCHIVE_DIR" -name "*.jsonl*" -mtime +90 -delete 2>/dev/null

exit 0

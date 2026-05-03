#!/bin/bash
LOG=/home/agent/workspace/.sandcastle/logs/claude-mcp.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
exec /home/agent/.local/bin/claude-real \
  --mcp-config /home/agent/workspace/.sandcastle/mcp-settings.json \
  --strict-mcp-config \
  --debug-file "$LOG" \
  "$@"

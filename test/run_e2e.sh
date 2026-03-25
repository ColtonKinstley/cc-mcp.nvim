#!/usr/bin/env bash
# End-to-end test runner: starts channel server, runs Neovim test, cleans up
set -euo pipefail

cd "$(dirname "$0")/.."

SOCK="/tmp/cc-mcp-e2e.sock"
PID_FILE="/tmp/cc-mcp-e2e.pid"

cleanup() {
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  rm -f "$SOCK"
}
trap cleanup EXIT

# Clean up any stale files
rm -f "$SOCK" "$PID_FILE"

# Start channel server in background (it reads MCP on stdin, so feed it nothing)
echo "Starting channel server..."
CC_MCP_SOCKET="$SOCK" bun run channel/server.ts < /dev/null &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

# Wait for socket to appear
for i in $(seq 1 20); do
  if [[ -S "$SOCK" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$SOCK" ]]; then
  echo "FAIL: Channel server did not create socket within 2 seconds"
  exit 1
fi

echo "Channel server running (PID $SERVER_PID, socket $SOCK)"
echo ""

# Run e2e tests in headless Neovim
nvim --headless -u NONE \
  --cmd "set rtp+=$(pwd)" \
  -l test/e2e_test.lua 2>&1

EXIT_CODE=$?

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "All E2E tests passed!"
else
  echo "E2E tests failed (exit $EXIT_CODE)"
fi

exit $EXIT_CODE

-- End-to-end test: Neovim connects to a real channel server over Unix socket
-- Run with: nvim --headless -u NONE --cmd "set rtp+=/Users/admin/src/tools/cc-mcp.nvim" -l test/e2e_test.lua
--
-- Requires the channel server to be running on the test socket:
--   CC_MCP_SOCKET=/tmp/cc-mcp-e2e.sock bun run channel/server.ts
-- (started by the test runner script)

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print("  PASS: " .. name)
  else
    fail = fail + 1
    print("  FAIL: " .. name .. " — " .. tostring(err))
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. vim.inspect(b) .. " got " .. vim.inspect(a))
  end
end

local function assert_true(v, msg)
  if not v then error(msg or "expected true") end
end

local SOCK = "/tmp/cc-mcp-e2e.sock"

print("\n=== cc-mcp.nvim E2E Tests ===\n")

-- ============================================================
print("--- Socket Connection ---")
-- ============================================================

-- Use a coroutine-like approach with vim.wait for async operations
local socket = require("cc-mcp.socket")
local rpc = require("cc-mcp.rpc")

-- Register RPC handler
rpc.setup()

-- Track received messages
local received_msgs = {}
local connected = false
local handshake_received = false

socket.on("handshake_ack", function(msg)
  handshake_received = true
  table.insert(received_msgs, msg)
end)

socket.on("reply_chunk", function(msg)
  table.insert(received_msgs, msg)
end)

socket.on("reply_end", function(msg)
  table.insert(received_msgs, msg)
end)

socket.on("error", function(msg)
  table.insert(received_msgs, msg)
end)

-- Connect to the server
local connect_err = nil
socket.connect(SOCK, function()
  connected = true
end, function(err)
  connect_err = err
end)

-- Wait for connection (up to 2 seconds)
vim.wait(2000, function() return connected or connect_err ~= nil end, 50)

test("connects to channel server", function()
  assert_true(connect_err == nil, "connection error: " .. tostring(connect_err))
  assert_true(connected, "should be connected")
end)

-- Wait for handshake_ack
vim.wait(1000, function() return handshake_received end, 50)

test("receives handshake_ack", function()
  assert_true(handshake_received, "should receive handshake_ack")
  assert_eq(received_msgs[1].type, "handshake_ack")
end)

test("socket reports connected", function()
  assert_true(socket.is_connected(), "should be connected")
end)

-- ============================================================
print("\n--- RPC Round-Trip ---")
-- ============================================================

-- Send a ping and check we get a pong
local pong_received = false
socket.on("pong", function()
  pong_received = true
end)

socket.send({ type = "ping" })
vim.wait(1000, function() return pong_received end, 50)

test("ping-pong round trip", function()
  assert_true(pong_received, "should receive pong")
end)

-- ============================================================
print("\n--- Disconnect ---")
-- ============================================================

test("disconnect works cleanly", function()
  socket.disconnect()
  assert_eq(socket.is_connected(), false)
end)

-- ============================================================
print("\n--- Results ---")
-- ============================================================

print(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))

if fail > 0 then
  vim.cmd("cquit 1")
end

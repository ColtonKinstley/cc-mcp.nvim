-- Test that Neovim can spawn the channel server and connect to it
-- Run with: nvim --headless -u NONE --cmd "set rtp+=/Users/admin/src/tools/cc-mcp.nvim" -l test/spawn_test.lua

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

-- Use a test-specific socket to avoid interfering with real usage
local test_sock = "/tmp/cc-mcp-spawn-test.sock"

print("\n=== cc-mcp.nvim Spawn + Connect Tests ===\n")

-- Clean up from previous runs
os.remove(test_sock)
os.remove(test_sock:gsub("%.sock$", ".pid"))

local singleton = require("cc-mcp.singleton")
local socket = require("cc-mcp.socket")
local rpc = require("cc-mcp.rpc")

-- Override socket path for this test
vim.env.CC_MCP_SOCKET = test_sock
-- Reload singleton to pick up new path
package.loaded["cc-mcp.singleton"] = nil
singleton = require("cc-mcp.singleton")

print("--- Server Spawn ---")

test("singleton.is_alive returns false before spawn", function()
  assert_eq(singleton.is_alive(), false)
end)

test("singleton.spawn starts the channel server", function()
  local ok = singleton.spawn()
  assert_true(ok, "spawn should return true")
end)

-- Wait for socket to appear
local socket_ready = false
singleton.wait_for_socket(function(success)
  socket_ready = success
end, 5000)

-- Spin the event loop while waiting
vim.wait(6000, function() return socket_ready end, 50)

test("channel server creates socket file", function()
  assert_true(socket_ready, "socket should be ready")
  assert_true(singleton.is_alive(), "server should be alive")
end)

print("\n--- Socket Connection ---")

local connected = false
local handshake_ok = false
local connect_err = nil

socket.on("handshake_ack", function(msg)
  handshake_ok = true
end)

rpc.setup()

socket.connect(test_sock, function()
  connected = true
end, function(err)
  connect_err = err
end)

vim.wait(2000, function() return connected or connect_err ~= nil end, 50)

test("Neovim connects to spawned server", function()
  assert_true(connect_err == nil, "error: " .. tostring(connect_err))
  assert_true(connected, "should be connected")
end)

vim.wait(1000, function() return handshake_ok end, 50)

test("receives handshake_ack from server", function()
  assert_true(handshake_ok, "should get handshake_ack")
end)

test("socket reports connected", function()
  assert_true(socket.is_connected(), "should be connected")
end)

print("\n--- Ping Round-Trip ---")

local pong_received = false
socket.on("pong", function()
  pong_received = true
end)

socket.send({ type = "ping" })
vim.wait(1000, function() return pong_received end, 50)

test("ping-pong round trip works", function()
  assert_true(pong_received, "should get pong")
end)

print("\n--- Chat Message Send ---")

-- We can't test the full Claude Code reply flow without MCP,
-- but we can verify the chat message is sent without error
test("chat message sends without error", function()
  local ok = socket.send({
    id = "m1",
    type = "chat",
    instance = vim.v.servername or "nvim-test",
    content = "test message",
  })
  assert_true(ok, "send should return true")
end)

print("\n--- Cleanup ---")

socket.disconnect()

test("disconnect works", function()
  assert_eq(socket.is_connected(), false)
end)

-- Kill the server
local pid_path = test_sock:gsub("%.sock$", ".pid")
local f = io.open(pid_path, "r")
if f then
  local pid = f:read("*a"):match("%d+")
  f:close()
  if pid then
    os.execute("kill " .. pid .. " 2>/dev/null")
  end
end
os.remove(test_sock)
os.remove(pid_path)

test("cleanup successful", function()
  assert_eq(vim.loop.fs_stat(test_sock), nil)
end)

print("\n--- Results ---")
print(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))

if fail > 0 then
  vim.cmd("cquit 1")
end

-- Functional tests for cc-mcp.nvim
-- Run with: nvim --headless -u NONE --cmd "set rtp+=/Users/admin/src/tools/cc-mcp.nvim" -l test/functional_test.lua

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

local function assert_contains(tbl, val, msg)
  for _, v in ipairs(tbl) do
    if v == val then return end
  end
  error((msg or "") .. " table does not contain " .. vim.inspect(val))
end

print("\n=== cc-mcp.nvim Functional Tests ===\n")

-- ============================================================
print("--- Module Loading ---")
-- ============================================================

test("require cc-mcp.socket", function()
  local socket = require("cc-mcp.socket")
  assert_true(socket.on ~= nil, "missing .on")
  assert_true(socket.send ~= nil, "missing .send")
  assert_true(socket.connect ~= nil, "missing .connect")
  assert_true(socket.disconnect ~= nil, "missing .disconnect")
  assert_true(socket.is_connected ~= nil, "missing .is_connected")
end)

test("require cc-mcp.rpc", function()
  local rpc = require("cc-mcp.rpc")
  assert_true(rpc.setup ~= nil, "missing .setup")
  assert_true(rpc.handle_request ~= nil, "missing .handle_request")
end)

test("require cc-mcp.chat", function()
  local chat = require("cc-mcp.chat")
  assert_true(chat.open ~= nil, "missing .open")
  assert_true(chat.close ~= nil, "missing .close")
  assert_true(chat.send_message ~= nil, "missing .send_message")
  assert_true(chat.approve ~= nil, "missing .approve")
  assert_true(chat.reject ~= nil, "missing .reject")
end)

test("require cc-mcp.singleton", function()
  local singleton = require("cc-mcp.singleton")
  assert_true(singleton.is_alive ~= nil, "missing .is_alive")
  assert_true(singleton.plugin_root ~= nil, "missing .plugin_root")
  assert_true(singleton.get_socket_path ~= nil, "missing .get_socket_path")
end)

test("require cc-mcp (init)", function()
  local ccmcp = require("cc-mcp")
  assert_true(ccmcp.setup ~= nil, "missing .setup")
  assert_true(ccmcp.open ~= nil, "missing .open")
end)

-- ============================================================
print("\n--- Socket Module ---")
-- ============================================================

test("socket starts disconnected", function()
  local socket = require("cc-mcp.socket")
  assert_eq(socket.is_connected(), false)
end)

test("socket.send returns false when disconnected", function()
  local socket = require("cc-mcp.socket")
  local ok = socket.send({ type = "ping" })
  assert_eq(ok, false)
end)

test("socket.on registers handlers without error", function()
  local socket = require("cc-mcp.socket")
  socket.on("test_event", function() end)
end)

-- ============================================================
print("\n--- Singleton Module ---")
-- ============================================================

test("singleton.get_socket_path returns default path", function()
  local singleton = require("cc-mcp.singleton")
  local path = singleton.get_socket_path()
  assert_true(path:match("cc%-mcp%.sock") ~= nil, "path should contain cc-mcp.sock, got: " .. path)
end)

test("singleton.is_alive returns false when no server running", function()
  local singleton = require("cc-mcp.singleton")
  assert_eq(singleton.is_alive(), false)
end)

test("singleton.plugin_root finds the plugin directory", function()
  local singleton = require("cc-mcp.singleton")
  local root = singleton.plugin_root()
  assert_true(root ~= nil, "plugin_root should find the plugin")
  assert_true(root:match("cc%-mcp%.nvim") ~= nil, "root should contain cc-mcp.nvim")
end)

-- ============================================================
print("\n--- Setup & Commands ---")
-- ============================================================

test("setup creates :Help command", function()
  local ccmcp = require("cc-mcp")
  ccmcp.setup()
  local cmds = vim.api.nvim_get_commands({})
  assert_true(cmds.Help ~= nil, ":Help command not found")
end)

test("setup creates FocusGained autocmd", function()
  local aus = vim.api.nvim_get_autocmds({ event = "FocusGained" })
  local found = false
  for _, au in ipairs(aus) do
    if au.callback then
      found = true
      break
    end
  end
  assert_true(found, "FocusGained autocmd not found")
end)

-- ============================================================
print("\n--- Chat Buffer ---")
-- ============================================================

test("chat.get_or_create_buf creates a valid buffer", function()
  local chat = require("cc-mcp.chat")
  local buf = chat.get_or_create_buf()
  assert_true(buf ~= nil, "buffer should not be nil")
  assert_true(vim.api.nvim_buf_is_valid(buf), "buffer should be valid")
end)

test("chat buffer has correct options", function()
  local chat = require("cc-mcp.chat")
  local buf = chat.get_or_create_buf()
  assert_eq(vim.bo[buf].buftype, "nofile")
  assert_eq(vim.bo[buf].filetype, "markdown")
  assert_eq(vim.bo[buf].swapfile, false)
end)

test("chat buffer has correct name", function()
  local chat = require("cc-mcp.chat")
  local buf = chat.get_or_create_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  assert_true(name:match("cc%-mcp://chat") ~= nil, "name should be cc-mcp://chat, got: " .. name)
end)

test("chat buffer initial content has separator", function()
  local chat = require("cc-mcp.chat")
  local buf = chat.get_or_create_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[1], "---", "first line should be separator")
  assert_eq(lines[2], "", "second line should be empty (input region)")
end)

test("get_or_create_buf returns same buffer on second call", function()
  local chat = require("cc-mcp.chat")
  local buf1 = chat.get_or_create_buf()
  local buf2 = chat.get_or_create_buf()
  assert_eq(buf1, buf2, "should return same buffer")
end)

test("clear_history resets buffer content", function()
  local chat = require("cc-mcp.chat")
  local buf = chat.get_or_create_buf()
  -- Add some content
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "## You", "hello", "" })
  chat.clear_history()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 2, "should have 2 lines after clear")
  assert_eq(lines[1], "---")
  assert_eq(lines[2], "")
end)

-- ============================================================
print("\n--- RPC Handlers ---")
-- ============================================================

test("rpc.handle_request responds to get_keymaps", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  -- Temporarily override socket.send to capture output
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-1",
    type = "request",
    method = "get_keymaps",
    params = { mode = "n" },
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil, "should have sent a response")
  assert_eq(sent_msg.id, "test-1")
  assert_eq(sent_msg.type, "response")
  assert_true(type(sent_msg.result) == "table", "result should be a table")
end)

test("rpc.handle_request responds to get_option", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-2",
    type = "request",
    method = "get_option",
    params = { name = "tabstop" },
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil, "should have sent a response")
  assert_eq(sent_msg.type, "response")
  assert_true(type(sent_msg.result) == "number", "tabstop should be a number")
end)

test("rpc.handle_request responds to list_buffers", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-3",
    type = "request",
    method = "list_buffers",
    params = {},
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  assert_true(type(sent_msg.result) == "table")
end)

test("rpc.handle_request responds to get_context", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-4",
    type = "request",
    method = "get_context",
    params = {},
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  local ctx = sent_msg.result
  assert_true(ctx.mode ~= nil, "context should have mode")
  assert_true(ctx.cursor_line ~= nil, "context should have cursor_line")
end)

test("rpc.handle_request responds to get_registers", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-5",
    type = "request",
    method = "get_registers",
    params = { registers = { '"', "0" } },
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  assert_true(type(sent_msg.result) == "table")
end)

test("rpc.handle_request responds to get_loaded_plugins", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-6",
    type = "request",
    method = "get_loaded_plugins",
    params = {},
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  assert_true(sent_msg.result.manager ~= nil, "should have manager field")
end)

test("rpc.handle_request returns error for unknown method", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-err",
    type = "request",
    method = "nonexistent_method",
    params = {},
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "error")
  assert_eq(sent_msg.code, "unknown_method")
end)

test("rpc.handle_request responds to exec_lua", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-exec",
    type = "request",
    method = "exec_lua",
    params = { code = "return 1 + 1" },
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  assert_eq(sent_msg.result.result, 2)
end)

test("rpc.handle_request exec_lua returns error on bad code", function()
  local rpc = require("cc-mcp.rpc")
  local socket = require("cc-mcp.socket")

  local sent_msg = nil
  local orig_send = socket.send
  socket.send = function(msg)
    sent_msg = msg
    return true
  end

  rpc.handle_request({
    id = "test-exec-err",
    type = "request",
    method = "exec_lua",
    params = { code = "error('test error')" },
  })

  socket.send = orig_send

  assert_true(sent_msg ~= nil)
  assert_eq(sent_msg.type, "response")
  assert_true(sent_msg.result.error ~= nil, "should have error field")
end)

-- ============================================================
print("\n--- Results ---")
-- ============================================================

print(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))

if fail > 0 then
  vim.cmd("cquit 1")
end

-- lua/cc-mcp/singleton.lua
-- Manages the Claude Code + channel server singleton process

local M = {}

local socket_path = os.getenv("CC_MCP_SOCKET") or "/tmp/cc-mcp.sock"
local pid_path = socket_path:gsub("%.sock$", ".pid")

-- Check if the server process is alive via PID file
local function pid_is_alive()
  local f = io.open(pid_path, "r")
  if not f then return false end
  local pid = f:read("*a")
  f:close()
  pid = pid and pid:match("%d+")
  if not pid then return false end
  -- kill -0 checks if process exists without sending a signal
  local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
  return ok == true or ok == 0
end

-- Clean up stale socket and PID files from a dead server
local function cleanup_stale()
  os.remove(socket_path)
  os.remove(pid_path)
end

-- Check if the socket is alive (file exists + process is running)
function M.is_alive()
  local stat = vim.loop.fs_stat(socket_path)
  if not stat then return false end
  if not pid_is_alive() then
    cleanup_stale()
    return false
  end
  return true
end

-- Get the plugin root directory (where .mcp.json lives)
function M.plugin_root()
  -- Find the plugin's install directory via the runtime path
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    if path:match("cc%-mcp%.nvim") then
      return path
    end
  end
  return nil
end

-- Spawn Claude Code as a detached process
function M.spawn()
  local root = M.plugin_root()
  if not root then
    vim.notify("cc-mcp: could not find plugin root directory", vim.log.levels.ERROR)
    return false
  end

  local nvim_config = vim.fn.stdpath("config")

  -- Spawn claude with --plugin-dir pointing to our plugin
  local handle, pid
  handle, pid = vim.loop.spawn("claude", {
    args = { "--plugin-dir", root },
    cwd = nvim_config,
    detached = true,
    stdio = { nil, nil, nil },
  }, function(code, signal)
    -- Process exited
    if handle then handle:close() end
  end)

  if not handle then
    vim.notify("cc-mcp: failed to spawn claude process", vim.log.levels.ERROR)
    return false
  end

  -- Detach so it survives Neovim exit
  handle:unref()
  return true
end

-- Wait for the socket to become available with exponential backoff
function M.wait_for_socket(callback, timeout_ms)
  timeout_ms = timeout_ms or 10000
  local elapsed = 0
  local delay = 50

  local function poll()
    if M.is_alive() then
      callback(true)
      return
    end

    elapsed = elapsed + delay
    if elapsed >= timeout_ms then
      callback(false)
      return
    end

    vim.defer_fn(function()
      poll()
    end, delay)

    -- Exponential backoff: 50, 100, 200, 400, 800, 1000, 1000, ...
    delay = math.min(delay * 2, 1000)
  end

  poll()
end

-- Ensure the server is running and connect
function M.ensure_running(on_ready, on_error)
  if M.is_alive() then
    on_ready()
    return
  end

  -- Spawn and wait
  local spawned = M.spawn()
  if not spawned then
    if on_error then on_error("Failed to spawn claude") end
    return
  end

  M.wait_for_socket(function(success)
    if success then
      on_ready()
    else
      if on_error then on_error("Timed out waiting for channel server") end
    end
  end)
end

function M.get_socket_path()
  return socket_path
end

return M

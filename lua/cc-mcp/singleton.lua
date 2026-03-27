-- lua/cc-mcp/singleton.lua
-- Checks whether the channel server is running (spawned by Claude Code via .mcp.json)

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
  local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
  return ok == true or ok == 0
end

-- Clean up stale socket and PID files from a dead server
local function cleanup_stale()
  os.remove(socket_path)
  os.remove(pid_path)
end

-- Check if the channel server is running (socket exists + process alive)
function M.is_alive()
  local stat = vim.loop.fs_stat(socket_path)
  if not stat then return false end
  if not pid_is_alive() then
    cleanup_stale()
    return false
  end
  return true
end

-- Get the plugin root directory
function M.plugin_root()
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    if path:match("cc%-mcp%.nvim") then
      return path
    end
  end
  return nil
end

function M.get_socket_path()
  return socket_path
end

return M

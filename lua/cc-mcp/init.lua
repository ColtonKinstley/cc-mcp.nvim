-- lua/cc-mcp/init.lua
-- Plugin entry point

local M = {}

local defaults = {
  send_key = nil, -- Override the send keybind if needed
  socket_path = nil, -- Override socket path
}

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Apply socket path override
  if opts.socket_path then
    vim.env.CC_MCP_SOCKET = opts.socket_path
  end

  -- Create :Help command
  vim.api.nvim_create_user_command("Help", function(cmd_opts)
    M.open(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, {
    nargs = "?",
    desc = "Open Claude Code chat for Neovim help",
  })

  -- FocusGained autocmd to track active instance
  vim.api.nvim_create_autocmd("FocusGained", {
    callback = function()
      local socket = require("cc-mcp.socket")
      if socket.is_connected() then
        local instance = vim.v.servername or ("nvim-" .. vim.fn.getpid())
        socket.send({ type = "focus", instance = instance })
      end
    end,
  })
end

-- Send a query immediately after opening the chat buffer
local function send_initial_query(query)
  local chat = require("cc-mcp.chat")
  local buf = chat.bufnr()
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last = #lines
    vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { query })
    chat.send_message()
    chat.goto_input()
  end
end

function M.open(query)
  local singleton = require("cc-mcp.singleton")
  local socket = require("cc-mcp.socket")
  local chat = require("cc-mcp.chat")
  local rpc = require("cc-mcp.rpc")

  -- Handle :Help reset — clear chat buffer, send reset signal
  if query == "reset" then
    if socket.is_connected() then
      socket.send({ type = "reset" })
    end
    chat.clear_history()
    vim.notify("cc-mcp: session reset", vim.log.levels.INFO)
    return
  end

  -- Ensure server is running
  singleton.ensure_running(function()
    -- Connect socket if not already
    if not socket.is_connected() then
      rpc.setup()
      socket.connect(singleton.get_socket_path(), function()
        chat.open()
        if query and query ~= "" then
          send_initial_query(query)
        end
      end, function(err)
        vim.notify("cc-mcp: connection failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    else
      chat.open()
      if query and query ~= "" then
        send_initial_query(query)
      end
    end
  end, function(err)
    vim.notify("cc-mcp: " .. tostring(err), vim.log.levels.ERROR)
  end)
end

return M

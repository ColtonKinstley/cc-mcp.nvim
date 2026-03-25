-- lua/cc-mcp/rpc.lua
-- Handles incoming state query requests from the channel server

local socket = require("cc-mcp.socket")

local M = {}

-- Dispatch table for RPC methods
local methods = {}

methods.get_keymaps = function(params)
  local mode = params.mode or "n"
  return vim.api.nvim_get_keymap(mode)
end

methods.get_option = function(params)
  local name = params.name
  local ok, val = pcall(vim.api.nvim_get_option_value, name, {})
  if ok then
    return val
  end
  return nil
end

methods.list_buffers = function()
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      table.insert(bufs, {
        bufnr = bufnr,
        name = vim.api.nvim_buf_get_name(bufnr),
        filetype = vim.bo[bufnr].filetype,
        modified = vim.bo[bufnr].modified,
        listed = vim.bo[bufnr].buflisted,
      })
    end
  end
  return bufs
end

methods.get_lsp_state = function()
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    table.insert(clients, {
      id = client.id,
      name = client.name,
      root_dir = client.config.root_dir,
      attached_buffers = vim.tbl_keys(client.attached_buffers or {}),
      capabilities = client.server_capabilities and vim.inspect(client.server_capabilities) or nil,
    })
  end
  -- Diagnostics summary
  local diagnostics = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local diags = vim.diagnostic.get(bufnr)
    if #diags > 0 then
      diagnostics[vim.api.nvim_buf_get_name(bufnr)] = {
        errors = #vim.tbl_filter(function(d) return d.severity == 1 end, diags),
        warnings = #vim.tbl_filter(function(d) return d.severity == 2 end, diags),
        info = #vim.tbl_filter(function(d) return d.severity == 3 end, diags),
        hints = #vim.tbl_filter(function(d) return d.severity == 4 end, diags),
      }
    end
  end
  return { clients = clients, diagnostics = diagnostics }
end

methods.get_loaded_plugins = function()
  -- Try lazy.nvim first
  local ok, lazy = pcall(require, "lazy")
  if ok then
    local plugins = {}
    for _, plugin in ipairs(lazy.plugins()) do
      table.insert(plugins, {
        name = plugin.name,
        dir = plugin.dir,
        loaded = plugin._.loaded ~= nil,
        url = plugin.url,
      })
    end
    return { manager = "lazy.nvim", plugins = plugins }
  end

  -- Fallback: inspect package.loaded
  local loaded = {}
  for name, _ in pairs(package.loaded) do
    table.insert(loaded, name)
  end
  table.sort(loaded)
  return { manager = "unknown", modules = loaded }
end

methods.get_context = function()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local mode = vim.api.nvim_get_mode()

  -- Get visual selection if in visual mode
  local selection = nil
  if mode.mode:match("[vV\22]") then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    selection = {
      start_line = start_pos[2],
      start_col = start_pos[3],
      end_line = end_pos[2],
      end_col = end_pos[3],
    }
  end

  return {
    file = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    cursor_line = cursor[1],
    cursor_col = cursor[2],
    mode = mode.mode,
    selection = selection,
    total_lines = vim.api.nvim_buf_line_count(buf),
  }
end

methods.get_registers = function(params)
  local reg_names = params and params.registers or { '"', "+", "*", "0", "1", "/" }
  local regs = {}
  for _, name in ipairs(reg_names) do
    regs[name] = vim.fn.getreg(name)
  end
  return regs
end

methods.get_treesitter = function()
  local buf = vim.api.nvim_get_current_buf()
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  local has_parser = false
  if lang then
    has_parser = pcall(vim.treesitter.get_parser, buf, lang)
  end
  return {
    buffer_language = lang,
    has_parser = has_parser,
    filetype = vim.bo[buf].filetype,
  }
end

methods.get_health = function()
  vim.cmd("redir => g:_cc_mcp_health")
  pcall(vim.cmd, "silent checkhealth")
  vim.cmd("redir END")
  local output = vim.g._cc_mcp_health or ""
  vim.g._cc_mcp_health = nil
  return { output = output }
end

methods.exec_lua = function(params)
  local ok, result = pcall(vim.api.nvim_exec_lua, params.code, {})
  if not ok then
    return { error = tostring(result) }
  end
  return { result = result }
end

methods.exec_command = function(params)
  local ok, err = pcall(vim.cmd, params.command)
  if not ok then
    return { error = err }
  end
  return { result = "ok" }
end

-- Handle an incoming request
function M.handle_request(msg)
  local method = methods[msg.method]
  if not method then
    socket.send({
      id = msg.id,
      type = "error",
      code = "unknown_method",
      message = "Unknown RPC method: " .. msg.method,
    })
    return
  end

  local ok, result = pcall(method, msg.params or {})
  if ok then
    socket.send({
      id = msg.id,
      type = "response",
      result = result,
    })
  else
    socket.send({
      id = msg.id,
      type = "error",
      code = "nvim_api_error",
      message = tostring(result),
    })
  end
end

-- Register the request handler with the socket
function M.setup()
  socket.on("request", function(msg)
    M.handle_request(msg)
  end)
end

return M

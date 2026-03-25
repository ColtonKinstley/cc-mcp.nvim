-- lua/cc-mcp/chat.lua
-- Chat buffer: creation, rendering, keybinds

local socket = require("cc-mcp.socket")

local M = {}

local chat_bufnr = nil
local chat_winnr = nil
local separator = "---"
local next_msg_id = 1
local ns_id = vim.api.nvim_create_namespace("cc_mcp_approval")

-- Get or create the chat buffer
function M.get_or_create_buf()
  if chat_bufnr and vim.api.nvim_buf_is_valid(chat_bufnr) then
    return chat_bufnr
  end

  chat_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[chat_bufnr].buftype = "nofile"
  vim.bo[chat_bufnr].filetype = "markdown"
  vim.bo[chat_bufnr].swapfile = false
  vim.bo[chat_bufnr].bufhidden = "hide"
  vim.api.nvim_buf_set_name(chat_bufnr, "cc-mcp://chat")

  -- Initial content: just the separator and empty input line
  vim.api.nvim_buf_set_lines(chat_bufnr, 0, -1, false, { separator, "" })

  M.setup_keymaps()
  M.setup_message_handlers()

  return chat_bufnr
end

-- Open the chat window (vertical split on the right)
function M.open()
  local buf = M.get_or_create_buf()

  -- Check if already open in a window
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      chat_winnr = win
      M.goto_input()
      return
    end
  end

  -- Open vertical split on the right
  vim.cmd("botright vsplit")
  chat_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat_winnr, buf)
  vim.wo[chat_winnr].wrap = true
  vim.wo[chat_winnr].linebreak = true
  vim.wo[chat_winnr].number = false
  vim.wo[chat_winnr].relativenumber = false
  vim.wo[chat_winnr].signcolumn = "no"

  M.goto_input()
end

-- Close the chat window
function M.close()
  if chat_winnr and vim.api.nvim_win_is_valid(chat_winnr) then
    vim.api.nvim_win_close(chat_winnr, true)
    chat_winnr = nil
  end
end

-- Move cursor to the input region (below separator) and enter insert mode
function M.goto_input()
  if not chat_bufnr or not vim.api.nvim_buf_is_valid(chat_bufnr) then return end

  local lines = vim.api.nvim_buf_get_lines(chat_bufnr, 0, -1, false)
  local last_line = #lines
  vim.api.nvim_win_set_cursor(0, { last_line, 0 })
  vim.cmd("startinsert!")
end

-- Find the separator line number (1-indexed)
local function find_separator()
  local lines = vim.api.nvim_buf_get_lines(chat_bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] == separator then
      return i
    end
  end
  return nil
end

-- Get text from the input region (below separator)
local function get_input_text()
  local sep_line = find_separator()
  if not sep_line then return "" end
  local lines = vim.api.nvim_buf_get_lines(chat_bufnr, sep_line, -1, false)
  return table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Clear the input region
local function clear_input()
  local sep_line = find_separator()
  if not sep_line then return end
  vim.api.nvim_buf_set_lines(chat_bufnr, sep_line, -1, false, { "" })
end

-- Append text above the separator (in the chat history)
local function append_to_history(lines_to_add)
  local sep_line = find_separator()
  if not sep_line then return end
  -- Insert before the separator
  vim.api.nvim_buf_set_lines(chat_bufnr, sep_line - 1, sep_line - 1, false, lines_to_add)
end

-- Send the user's message
function M.send_message()
  local text = get_input_text()
  if text == "" then return end

  -- Append user message to history
  local user_lines = { "", "## You", "" }
  for line in text:gmatch("[^\n]+") do
    table.insert(user_lines, line)
  end
  table.insert(user_lines, "")
  append_to_history(user_lines)

  -- Clear input
  clear_input()

  -- Append Claude header
  append_to_history({ "## Claude", "" })

  -- Send over socket
  local msg_id = "m" .. next_msg_id
  next_msg_id = next_msg_id + 1

  local instance = vim.v.servername or ("nvim-" .. vim.fn.getpid())
  socket.send({
    id = msg_id,
    type = "chat",
    instance = instance,
    content = text,
  })
end

-- Handle streaming reply chunks
local function handle_reply_chunk(msg)
  if not chat_bufnr or not vim.api.nvim_buf_is_valid(chat_bufnr) then return end

  local sep_line = find_separator()
  if not sep_line then return end

  -- Insert reply text just above the separator
  local lines = {}
  for line in msg.content:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  -- Remove trailing empty string from split
  if lines[#lines] == "" then
    table.remove(lines)
  end

  if #lines > 0 then
    vim.api.nvim_buf_set_lines(chat_bufnr, sep_line - 1, sep_line - 1, false, lines)
  end
end

local function handle_reply_end(msg)
  -- Add trailing blank line after Claude's response
  if chat_bufnr and vim.api.nvim_buf_is_valid(chat_bufnr) then
    local sep_line = find_separator()
    if sep_line then
      vim.api.nvim_buf_set_lines(chat_bufnr, sep_line - 1, sep_line - 1, false, { "" })
    end
  end
end

-- Handle approval requests
local function handle_approval(msg)
  if not chat_bufnr or not vim.api.nvim_buf_is_valid(chat_bufnr) then return end

  local sep_line = find_separator()
  if not sep_line then return end

  local lines = {
    "",
    "**" .. msg.description .. "**",
    "",
    "```" .. msg.lang,
  }
  for line in msg.code:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  if lines[#lines] == "" then table.remove(lines) end
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "**[Enter] Approve  [x] Reject  [e] Edit**")
  table.insert(lines, "")

  vim.api.nvim_buf_set_lines(chat_bufnr, sep_line - 1, sep_line - 1, false, lines)

  -- Store approval ID as buffer variable for the keybinds to use
  vim.b[chat_bufnr].pending_approval_id = msg.id

  -- Add extmark for the approval block
  local mark_line = sep_line - 1 -- The line where we inserted
  vim.api.nvim_buf_set_extmark(chat_bufnr, ns_id, mark_line, 0, {
    end_row = mark_line + #lines,
    hl_group = "Visual",
    priority = 10,
  })
end

-- Setup socket message handlers
function M.setup_message_handlers()
  socket.on("reply_chunk", handle_reply_chunk)
  socket.on("reply_end", handle_reply_end)
  socket.on("approval", handle_approval)
  socket.on("handshake_ack", function()
    vim.notify("cc-mcp: connected to channel server", vim.log.levels.INFO)
  end)
  socket.on("disconnected", function()
    vim.notify("cc-mcp: disconnected from channel server", vim.log.levels.WARN)
  end)
end

-- Approve the pending approval
function M.approve()
  local approval_id = vim.b[chat_bufnr] and vim.b[chat_bufnr].pending_approval_id
  if not approval_id then
    vim.notify("No pending approval", vim.log.levels.WARN)
    return
  end
  socket.send({ id = approval_id, type = "verdict", approved = true })
  vim.b[chat_bufnr].pending_approval_id = nil
  vim.api.nvim_buf_clear_namespace(chat_bufnr, ns_id, 0, -1)
  M.goto_input()
end

-- Reject the pending approval
function M.reject()
  local approval_id = vim.b[chat_bufnr] and vim.b[chat_bufnr].pending_approval_id
  if not approval_id then
    vim.notify("No pending approval", vim.log.levels.WARN)
    return
  end
  socket.send({ id = approval_id, type = "verdict", approved = false })
  vim.b[chat_bufnr].pending_approval_id = nil
  vim.api.nvim_buf_clear_namespace(chat_bufnr, ns_id, 0, -1)
  M.goto_input()
end

-- Setup buffer-local keymaps
function M.setup_keymaps()
  local buf = chat_bufnr
  local opts = { buffer = buf, silent = true }

  -- Send message on <CR> in insert mode
  vim.keymap.set("i", "<CR>", function()
    -- Only send if cursor is in the input region
    local sep_line = find_separator()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    if sep_line and cursor_line >= sep_line then
      vim.cmd("stopinsert")
      M.send_message()
      M.goto_input()
    else
      -- Normal enter behavior above separator
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end
  end, opts)

  -- Newline fallback: <C-j>
  vim.keymap.set("i", "<C-j>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, opts)

  -- Try <S-CR> for newline (works with CSI-u/kitty protocol)
  vim.keymap.set("i", "<S-CR>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
  end, opts)

  -- Approve: <CR> in normal mode (on approval block)
  vim.keymap.set("n", "<CR>", function()
    if vim.b[buf].pending_approval_id then
      M.approve()
    end
  end, opts)

  -- Reject: x in normal mode (on approval block)
  vim.keymap.set("n", "x", function()
    if vim.b[buf].pending_approval_id then
      M.reject()
    else
      -- Normal x behavior
      vim.api.nvim_feedkeys("x", "n", false)
    end
  end, opts)

  -- Edit before approving: e
  vim.keymap.set("n", "e", function()
    if vim.b[buf].pending_approval_id then
      -- Jump to the code block content for editing
      -- User can edit, then press <CR> to approve or x to reject
      vim.notify("Edit the code block above, then press Enter to approve or x to reject", vim.log.levels.INFO)
    else
      vim.api.nvim_feedkeys("e", "n", false)
    end
  end, opts)

  -- Jump to next/previous approval block: ]a / [a
  vim.keymap.set("n", "]a", function()
    vim.fn.search("^\\*\\*\\[Enter\\] Approve", "W")
  end, opts)

  vim.keymap.set("n", "[a", function()
    vim.fn.search("^\\*\\*\\[Enter\\] Approve", "bW")
  end, opts)

  -- Close: gq
  vim.keymap.set("n", "gq", function()
    M.close()
  end, opts)

  -- Cancel: <C-c>
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    -- TODO: send cancel signal
    vim.notify("cc-mcp: cancel not yet implemented", vim.log.levels.INFO)
  end, opts)
end

-- Clear chat history (for :Help reset)
function M.clear_history()
  if chat_bufnr and vim.api.nvim_buf_is_valid(chat_bufnr) then
    vim.api.nvim_buf_set_lines(chat_bufnr, 0, -1, false, { separator, "" })
  end
end

-- Get the buffer number (for external use)
function M.bufnr()
  return chat_bufnr
end

return M

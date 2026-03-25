-- lua/cc-mcp/socket.lua
-- Unix domain socket client using vim.loop (libuv)

local M = {}

local protocol_version = "1"
local pipe = nil
local buffer = ""
local handlers = {}
local connected = false

-- Register a handler for a message type
function M.on(msg_type, handler)
  handlers[msg_type] = handler
end

-- Send a message over the socket
function M.send(msg)
  if not connected or not pipe then
    return false
  end
  local json = vim.json.encode(msg) .. "\n"
  pipe:write(json)
  return true
end

-- Process accumulated buffer for complete NDJSON lines
local function process_buffer()
  while true do
    local newline_pos = buffer:find("\n")
    if not newline_pos then break end

    local line = buffer:sub(1, newline_pos - 1)
    buffer = buffer:sub(newline_pos + 1)

    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and msg and msg.type then
        local handler = handlers[msg.type]
        if handler then
          vim.schedule(function()
            handler(msg)
          end)
        end
      end
    end
  end
end

-- Connect to the Unix socket
function M.connect(socket_path, on_connected, on_error)
  if connected then
    if on_connected then on_connected() end
    return
  end

  pipe = vim.loop.new_pipe(false)
  pipe:connect(socket_path, function(err)
    if err then
      vim.schedule(function()
        if on_error then on_error(err) end
      end)
      return
    end

    connected = true
    buffer = ""

    -- Start reading
    pipe:read_start(function(read_err, data)
      if read_err then
        vim.schedule(function()
          if on_error then on_error(read_err) end
        end)
        return
      end
      if data then
        buffer = buffer .. data
        process_buffer()
      else
        -- EOF — server disconnected
        connected = false
        pipe:close()
        pipe = nil
        local handler = handlers["disconnected"]
        if handler then
          vim.schedule(function() handler() end)
        end
      end
    end)

    -- Send handshake
    local instance = vim.v.servername or ("nvim-" .. vim.fn.getpid())
    M.send({
      type = "handshake",
      instance = instance,
      version = protocol_version,
    })

    vim.schedule(function()
      if on_connected then on_connected() end
    end)
  end)
end

-- Disconnect
function M.disconnect()
  if pipe then
    pipe:read_stop()
    pipe:close()
    pipe = nil
  end
  connected = false
  buffer = ""
end

-- Check if connected
function M.is_connected()
  return connected
end

return M

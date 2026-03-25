# cc-mcp.nvim Design Spec

## Overview

cc-mcp.nvim is a dual-purpose plugin — a Neovim plugin and a Claude Code plugin in one repository. It provides a chat buffer inside Neovim backed by a persistent Claude Code session, connected via an MCP channel server over a Unix domain socket. Claude has full access to the Neovim configuration (`~/.config/nvim`), can query live Neovim runtime state, and can modify configuration with user approval.

## Architecture

Three components:

```
┌─────────────────────────┐
│  Claude Code Session    │
│  cwd: ~/.config/nvim    │
│                         │
│  • Reads/writes config  │
│  • Full tool access     │
│  • Persistent session   │
└────────────┬────────────┘
             │ stdio (Claude Code spawns this)
             ▼
┌─────────────────────────┐
│  Channel Server (Bun/TS)│
│                         │
│  • MCP stdio transport  │──── child process of Claude Code
│  • Unix socket server   │──── listens for Neovim connections
│  • Neovim state tools   │──── calls back to Neovim RPC
│  • Reply tool           │──── streams responses to Neovim
└────────────┬────────────┘
             │  Newline-delimited JSON
             │  over Unix socket
             ▼
┌─────────────────────────┐
│  cc-mcp.nvim (Lua)      │
│                         │
│  • Chat buffer UI       │
│  • Neovim RPC server    │  ◄── Claude queries state here
│  • Unix socket client   │
└─────────────────────────┘
```

### Lifecycle

1. User runs `:Help` (or keymap) in Neovim.
2. Plugin checks for a running channel server (socket file + PID file).
3. If not running, spawns `claude --plugin-dir <plugin-root>` as a detached process with `cwd=~/.config/nvim`. Claude Code reads the `.mcp.json` at the plugin root, discovers the channel server, and launches it as a stdio subprocess. The channel server binds the Unix socket on startup.
4. Neovim polls for the socket file with exponential backoff (50ms, 100ms, 200ms, ...) up to a 10-second timeout. If the socket never appears, the plugin reports an error via `vim.notify` and aborts.
5. Once the socket is live, Neovim connects and sends a handshake message. The chat buffer opens.
6. User types a message -> plugin sends over socket -> channel forwards to Claude Code.
7. Claude Code responds (possibly calling MCP tools to query Neovim state) -> channel streams back over socket -> plugin renders in chat buffer.
8. If Claude proposes a mutation, it appears as a code block with approve/reject keybinds.

## Singleton Management

Multiple Neovim instances share a single Claude Code session and channel server.

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Neovim 1 │  │ Neovim 2 │  │ Neovim 3 │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │              │              │
     │   all connect to same socket
     │              │              │
     └──────────────┼──────────────┘
                    ▼
         ┌──────────────────┐
         │  Channel Server  │  (singleton)
         │  /tmp/cc-mcp.sock│
         └──────────────────┘
                    ▲ stdio (child of Claude Code)
                    │
         ┌──────────────────┐
         │  Claude Code     │  (one session)
         └──────────────────┘
```

- **Socket path:** `/tmp/cc-mcp.sock` (or `$XDG_RUNTIME_DIR/cc-mcp.sock`).
- **First instance** to run `:Help` checks if the socket exists and is responsive (sends a ping, expects a pong). If not responsive, spawns Claude Code as a detached process. Claude Code launches the channel server via `.mcp.json`, which binds the socket. A PID file (`/tmp/cc-mcp.pid`) is written by the channel server after binding.
- **Subsequent instances** find the socket live and connect directly.
- **Instance identification:** Each Neovim connection sends a handshake with a unique instance ID (`v:servername`) and protocol version. The channel server tracks active connections.
- **Active instance routing:** When Claude calls MCP tools to query Neovim state, the channel server routes the query to the **focused** instance. The Neovim plugin sends a lightweight `focus` event on the `FocusGained` autocmd so the channel server always knows which editor is active. Falls back to the most recent chat sender if no focus event has been received.
- **Cleanup:** Channel server detects disconnects. When the last Neovim instance disconnects, the server shuts down after a 5-minute idle timeout. PID file and socket are cleaned up on exit. If the Claude Code parent process exits, the channel server exits too (stdio closes).

### File Mutations and Permissions

Claude Code runs in its default permission mode. When Claude Code wants to write a file (via its built-in Edit/Write tools), its standard permission prompt fires. The channel server intercepts these prompts via the `claude/channel/permission` capability and forwards them to the active Neovim instance as approval requests in the chat buffer. This unifies the approval experience — all mutations (file writes and Neovim commands) appear as reviewable blocks in the chat buffer.

## Chat Buffer UX

### Layout

- `:Help` opens a vertical split on the right.
- Buffer is scratch (`buftype=nofile`), `filetype=markdown` for syntax highlighting and render-markdown.nvim support.
- `:Help <query>` opens the buffer and immediately sends the query.

### Buffer Format

```markdown
## You
What does <leader>d do?

## Claude
`<leader>d` is mapped to `vim.lsp.buf.definition()` in your
`lua/config/mappings.lua` (line 24). It jumps to the definition
of the symbol under your cursor using the LSP.

## You
Add a keymap to toggle a terminal split

## Claude
I'll add this to your mappings. Here's what I'll do:

\`\`\`lua
vim.keymap.set('n', '<leader>t', function()
  vim.cmd('botright split | terminal')
end, { desc = 'Toggle terminal split' })
\`\`\`

**[Enter] Approve  [x] Reject  [e] Edit**
```

### Input Model

- A separator line (`---`) divides chat history (above) from input region (below).
- Entering the chat window places cursor in the input region in insert mode.
- `<CR>` sends the message.
- `<S-CR>` inserts a newline (multi-line input).
- After sending, input clears, message appears in history above, cursor stays in input region.
- `gg` / scroll to browse history. `G` or `gi` to return to input.

**Terminal compatibility note:** `<S-CR>` requires CSI-u or kitty keyboard protocol support. Terminals that don't support modified keys (standard Terminal.app, iTerm2 without CSI-u, tmux without `extended-keys`) will not distinguish `<S-CR>` from `<CR>`. Fallback: `<C-j>` inserts a newline in insert mode. The `setup()` function accepts a `send_key` option to override the send binding.

### Keybinds

| Key | Context | Action |
|-----|---------|--------|
| `<CR>` | Insert, input region | Send message |
| `<S-CR>` | Insert, input region | Insert newline (requires CSI-u/kitty protocol) |
| `<C-j>` | Insert, input region | Insert newline (universal fallback) |
| `<CR>` | Normal, on approval code block | Approve mutation |
| `x` | Normal, on approval code block | Reject mutation |
| `e` | Normal, on approval code block | Edit code before approving |
| `<C-c>` | Any | Cancel in-progress response |
| `gq` | Normal | Close chat buffer |
| `]a` / `[a` | Normal | Jump to next/previous approval code block |

**Keybind rationale:** `x` for reject avoids shadowing `q` (macro recording). `]a`/`[a` ("approval") avoids shadowing `]c`/`[c` (diff hunk navigation).

### Streaming

As Claude responds, text appears incrementally in the buffer. Cursor stays in the input region so the user can compose the next message.

### Approval Flow

Code blocks that require approval render with virtual text markers. The user navigates to them with `]a`/`[a`, reviews the code, and presses `<CR>` to approve or `x` to reject. After acting, cursor returns to the input region.

## Transport: Unix Domain Socket

### Why Unix Socket

- No port allocation, no TCP overhead, no port conflicts.
- `vim.loop` (libuv) has native support via `uv.new_pipe()`.
- Bun supports Unix sockets natively via `Bun.listen`.
- Only local processes with filesystem access can connect.

### Protocol: Newline-Delimited JSON (v1)

Every message is a single JSON object terminated by `\n`. Each has a `type` field. Request/response pairs share an `id` for correlation.

```jsonc
// Neovim → Channel: handshake (sent on connect)
{"type": "handshake", "instance": "nvim-12345", "version": "1"}

// Channel → Neovim: handshake acknowledgement
{"type": "handshake_ack", "version": "1"}

// Neovim → Channel: instance gained focus
{"type": "focus", "instance": "nvim-12345"}

// Channel → Neovim: state query
{"id": "r1", "type": "request", "method": "get_keymaps", "params": {"mode": "n"}}

// Neovim → Channel: query response
{"id": "r1", "type": "response", "result": [...]}

// Neovim → Channel: user chat message
{"id": "m1", "type": "chat", "instance": "nvim-12345", "content": "What does leader-d do?"}

// Channel → Neovim: streaming reply
{"id": "m1", "type": "reply_chunk", "content": "`<leader>d` is mapped to..."}
{"id": "m1", "type": "reply_end"}

// Channel → Neovim: mutation approval request
{"id": "a1", "type": "approval", "code": "vim.keymap.set(...)", "lang": "lua", "description": "Add terminal toggle keymap"}

// Neovim → Channel: approval verdict
{"id": "a1", "type": "verdict", "approved": true}

// Either direction: error
{"id": "r1", "type": "error", "code": "nvim_api_error", "message": "Buffer not found"}

// Channel → Neovim: ping (health check)
{"type": "ping"}

// Neovim → Channel: pong
{"type": "pong"}
```

If the handshake `version` does not match, the channel server responds with an error and closes the connection. This prevents silent breakage from version mismatches after partial updates.

## MCP Tools

### Read-Only (Auto-Approved)

| MCP Tool | Neovim API | Returns |
|----------|-----------|---------|
| `nvim_get_keymaps` | `vim.api.nvim_get_keymap(mode)` | All mappings for a given mode with source info |
| `nvim_get_option` | `vim.api.nvim_get_option_value()` | Value of a specific option |
| `nvim_list_buffers` | `vim.api.nvim_list_bufs()` + metadata | Buffer list with names, filetypes, modified state |
| `nvim_get_lsp_state` | `vim.lsp.get_clients()` | Attached LSP clients, capabilities, diagnostics |
| `nvim_get_treesitter` | `pcall(vim.treesitter.get_parser)` per buffer | Active parsers and installed languages. Falls back to nvim-treesitter's `installed_parsers()` if present |
| `nvim_get_loaded_plugins` | Detects plugin manager (lazy.nvim, packer, mini.deps) | Plugin list with load status. Falls back to `package.loaded` inspection if no manager found |
| `nvim_get_registers` | `vim.fn.getreg()` | Register contents |
| `nvim_get_context` | Cursor, file, mode, selection | Current editing context |
| `nvim_get_health` | `vim.health` module internals | Best-effort health check output. Captures via `:redir`; output is unstructured text. May not work for all health check providers |

### Mutation (Require Approval)

| MCP Tool | Neovim API | Approval |
|----------|-----------|----------|
| `nvim_exec_lua` | `vim.api.nvim_exec_lua()` | Code block in chat buffer, `<CR>` to approve |
| `nvim_exec_command` | `vim.api.nvim_command()` | Command shown in chat buffer, `<CR>` to approve |

## Specialized Agents

Defined as Claude Code plugin agents in `.claude-plugin/agents/`. The main Claude Code session dispatches them based on the user's message.

| Agent | Purpose | Access |
|-------|---------|--------|
| **config-researcher** | Answers questions about current config | Reads `~/.config/nvim/**`, queries Neovim state via MCP tools |
| **config-modifier** | Makes config changes (keymaps, plugin configs, options) | Reads/writes config files, can execute Lua in Neovim to hot-reload |
| **plugin-researcher** | Finds and evaluates Neovim plugins | Web search, reads plugin docs, checks compatibility with current setup |
| **troubleshooter** | Debugs issues (LSP not attaching, keymap conflicts, etc.) | Reads config, queries Neovim state, can run `:checkhealth` |
| **keymap-advisor** | Analyzes keymap landscape, finds free keys, detects conflicts | Queries full keymap state, cross-references which-key groups |

Routing is automatic (Claude decides which agent fits the message) but can be explicit if the user wants a specific agent.

## Plugin Structure

```
cc-mcp.nvim/
├── .mcp.json                       # MCP server declaration for Claude Code
├── .claude-plugin/
│   ├── plugin.json                 # Claude Code plugin manifest
│   ├── agents/
│   │   ├── config-researcher.md
│   │   ├── config-modifier.md
│   │   ├── plugin-researcher.md
│   │   ├── troubleshooter.md
│   │   └── keymap-advisor.md
│   ├── skills/
│   │   ├── add-keymap.md           # Guided keymap creation
│   │   ├── add-plugin.md           # Guided plugin installation
│   │   ├── health-check.md         # Run diagnostics on config
│   │   └── explain-config.md       # Walk through a config file
│   └── hooks/
│       └── (future)
├── channel/
│   ├── package.json                # Bun deps (@modelcontextprotocol/sdk)
│   ├── server.ts                   # Channel server: MCP stdio + Unix socket
│   └── nvim-tools.ts              # MCP tool definitions for Neovim state queries
├── lua/
│   └── cc-mcp/
│       ├── init.lua                # Plugin entry, setup()
│       ├── chat.lua                # Chat buffer: creation, rendering, keybinds
│       ├── socket.lua              # Unix socket client (vim.loop/uv.new_pipe)
│       ├── rpc.lua                 # RPC server: handles state queries from channel
│       ├── approval.lua            # Approve/reject UI for mutations
│       └── singleton.lua           # Server lifecycle, PID file management
└── README.md
```

### .mcp.json

Declares the channel server so Claude Code spawns it automatically:

```json
{
  "mcpServers": {
    "cc-mcp": {
      "command": "bun",
      "args": ["run", "channel/server.ts"]
    }
  }
}
```

### Installation in Neovim

lazy.nvim spec:

```lua
{
  "user/cc-mcp.nvim",
  cmd = "Help",
  keys = { { "<leader>h", "<cmd>Help<cr>", desc = "Claude Help" } },
  build = "cd channel && bun install",
  opts = {
    -- send_key = "<C-CR>",  -- override if terminal supports it
  },
}
```

The `build` step runs `bun install` in the `channel/` directory to install the MCP SDK dependency. The plugin lazy-loads on the `:Help` command.

## Session Context Management

The Claude Code session accumulates context over time. To prevent unbounded growth:

- The session's CLAUDE.md (at `~/.config/nvim/CLAUDE.md`) provides standing context about the config structure so Claude doesn't need to rediscover it each time.
- Claude Code's built-in context compaction handles long conversations automatically.
- `:Help reset` command sends a session reset signal, starting a fresh Claude Code conversation while keeping the same channel server and socket connection alive.

## Key Design Decisions

1. **Dual plugin:** One repo serves as both a Neovim plugin (Lua) and a Claude Code plugin (agents/skills/hooks). Loaded via `lazy.nvim` in Neovim and `--plugin-dir` in Claude Code.
2. **Unix socket over WebSocket/HTTP:** No port conflicts, no external dependencies, native support on both sides. Newline-delimited JSON for framing with protocol versioning.
3. **Singleton channel server:** One Claude Code session shared across all Neovim instances. First instance spawns, others connect. Focused instance receives state queries.
4. **Tiered trust:** Read-only state queries auto-approve. Mutations (exec_lua, exec_command, file writes) require explicit approval in the chat buffer.
5. **Claude Code does the heavy lifting:** The Neovim plugin is a thin UI layer. File reads/writes, web search, and complex reasoning all happen in the Claude Code session with its full toolset.
6. **Channel server as bridge:** Translates between the MCP protocol (Claude Code) and the custom NDJSON protocol (Neovim). Also hosts the MCP tools that query Neovim state.
7. **Unified approval UX:** Both Claude Code's file-write permissions and Neovim command execution approvals are surfaced in the chat buffer, so the user has one place to review and approve all mutations.
8. **`:Help` command name:** Intentionally chosen for discoverability. Note: Neovim's built-in `:help` is lowercase and case-sensitive in Lua-defined commands, so there is no conflict.

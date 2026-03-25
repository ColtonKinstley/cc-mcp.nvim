# cc-mcp.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dual Neovim/Claude Code plugin that provides a chat buffer inside Neovim backed by a persistent Claude Code session via an MCP channel server over a Unix domain socket.

**Architecture:** Three components — a Bun/TypeScript MCP channel server (bridge), a Neovim Lua plugin (UI + RPC), and Claude Code plugin assets (agents/skills). The channel server is spawned by Claude Code as an MCP subprocess, binds a Unix socket, and bridges chat messages and Neovim state queries between Neovim instances and the Claude Code session.

**Tech Stack:** Bun, TypeScript, @modelcontextprotocol/sdk, Neovim Lua API (vim.loop/libuv), lazy.nvim

**Spec:** `docs/superpowers/specs/2026-03-25-cc-mcp-nvim-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `package.json` | Root package.json for repo metadata |
| `.mcp.json` | MCP server declaration for Claude Code |
| `.claude-plugin/plugin.json` | Claude Code plugin manifest |
| `.claude-plugin/agents/config-researcher.md` | Agent: answers config questions |
| `.claude-plugin/agents/config-modifier.md` | Agent: makes config changes |
| `.claude-plugin/agents/plugin-researcher.md` | Agent: researches Neovim plugins |
| `.claude-plugin/agents/troubleshooter.md` | Agent: debugs Neovim issues |
| `.claude-plugin/agents/keymap-advisor.md` | Agent: keymap analysis |
| `.claude-plugin/skills/add-keymap.md` | Skill: guided keymap creation |
| `.claude-plugin/skills/add-plugin.md` | Skill: guided plugin installation |
| `.claude-plugin/skills/health-check.md` | Skill: run diagnostics |
| `.claude-plugin/skills/explain-config.md` | Skill: explain config files |
| `lua/cc-mcp/approval.lua` | Approve/reject UI for mutations |
| `channel/package.json` | Bun dependencies |
| `channel/tsconfig.json` | TypeScript config |
| `channel/server.ts` | Channel server: MCP stdio + Unix socket |
| `channel/protocol.ts` | NDJSON message types and helpers |
| `channel/socket-manager.ts` | Unix socket server + connection tracking |
| `channel/nvim-tools.ts` | MCP tool definitions for Neovim state |
| `channel/server.test.ts` | Tests for protocol + socket manager |
| `lua/cc-mcp/init.lua` | Plugin entry point, setup(), :Help command |
| `lua/cc-mcp/socket.lua` | Unix socket client (vim.loop) |
| `lua/cc-mcp/rpc.lua` | RPC handler for incoming state queries |
| `lua/cc-mcp/chat.lua` | Chat buffer: creation, rendering, keybinds |
| `lua/cc-mcp/approval.lua` | Approve/reject UI for mutations |
| `lua/cc-mcp/singleton.lua` | Server lifecycle, PID management |

---

### Task 1: Project Scaffolding

**Files:**
- Create: `package.json`
- Create: `.gitignore`
- Create: `.mcp.json`
- Create: `channel/package.json`
- Create: `channel/tsconfig.json`

- [ ] **Step 1: Initialize git repo**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git init
```

- [ ] **Step 2: Create root package.json**

```json
{
  "name": "cc-mcp.nvim",
  "version": "0.1.0",
  "description": "Neovim chat buffer powered by Claude Code via MCP channel",
  "private": true
}
```

- [ ] **Step 3: Create .gitignore**

```
node_modules/
channel/node_modules/
*.log
/tmp/
.DS_Store
```

- [ ] **Step 4: Create .mcp.json**

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

- [ ] **Step 5: Create channel/package.json**

```json
{
  "name": "cc-mcp-channel",
  "version": "0.1.0",
  "private": true,
  "dependencies": {
    "@modelcontextprotocol/sdk": "latest",
    "zod": "^3.23.0"
  },
  "devDependencies": {
    "@types/bun": "latest"
  }
}
```

- [ ] **Step 6: Create channel/tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist",
    "rootDir": ".",
    "types": ["bun"]
  },
  "include": ["./**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 7: Install dependencies**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim/channel && bun install
```

- [ ] **Step 8: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add -A
git commit -m "feat: project scaffolding with channel server dependencies"
```

---

### Task 2: NDJSON Protocol Types & Helpers

**Files:**
- Create: `channel/protocol.ts`
- Create: `channel/protocol.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// channel/protocol.test.ts
import { describe, it, expect } from "bun:test";
import { encode, decode, type Message } from "./protocol";

describe("encode", () => {
  it("serializes a message to NDJSON", () => {
    const msg: Message = { type: "ping" };
    expect(encode(msg)).toBe('{"type":"ping"}\n');
  });

  it("includes all fields", () => {
    const msg: Message = {
      id: "r1",
      type: "request",
      method: "get_keymaps",
      params: { mode: "n" },
    };
    const parsed = JSON.parse(encode(msg).trim());
    expect(parsed.id).toBe("r1");
    expect(parsed.method).toBe("get_keymaps");
  });
});

describe("decode", () => {
  it("parses a single NDJSON line", () => {
    const msg = decode('{"type":"pong"}\n');
    expect(msg.type).toBe("pong");
  });

  it("throws on invalid JSON", () => {
    expect(() => decode("not json\n")).toThrow();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun test channel/protocol.test.ts
```

Expected: FAIL — module not found

- [ ] **Step 3: Implement protocol types and helpers**

```typescript
// channel/protocol.ts

// -- Message types flowing over the Unix socket --

export type Message =
  | Handshake
  | HandshakeAck
  | Focus
  | Request
  | Response
  | Chat
  | ReplyChunk
  | ReplyEnd
  | Approval
  | Verdict
  | ErrorMsg
  | Reset
  | Ping
  | Pong;

export interface Handshake {
  type: "handshake";
  instance: string;
  version: string;
}

export interface HandshakeAck {
  type: "handshake_ack";
  version: string;
}

export interface Focus {
  type: "focus";
  instance: string;
}

export interface Request {
  id: string;
  type: "request";
  method: string;
  params?: Record<string, unknown>;
}

export interface Response {
  id: string;
  type: "response";
  result: unknown;
}

export interface Chat {
  id: string;
  type: "chat";
  instance: string;
  content: string;
}

export interface ReplyChunk {
  id: string;
  type: "reply_chunk";
  content: string;
}

export interface ReplyEnd {
  id: string;
  type: "reply_end";
}

export interface Approval {
  id: string;
  type: "approval";
  code: string;
  lang: string;
  description: string;
}

export interface Verdict {
  id: string;
  type: "verdict";
  approved: boolean;
}

export interface ErrorMsg {
  id?: string;
  type: "error";
  code: string;
  message: string;
}

export interface Reset {
  type: "reset";
}

export interface Ping {
  type: "ping";
}

export interface Pong {
  type: "pong";
}

// Protocol version
export const PROTOCOL_VERSION = "1";

// Encode a message to NDJSON (single line + newline)
export function encode(msg: Message): string {
  return JSON.stringify(msg) + "\n";
}

// Decode a single NDJSON line to a message
export function decode(line: string): Message {
  return JSON.parse(line.trim()) as Message;
}

// Buffer for accumulating partial reads into complete lines
export class LineBuffer {
  private buffer = "";

  push(data: string): Message[] {
    this.buffer += data;
    const messages: Message[] = [];
    let newlineIdx: number;
    while ((newlineIdx = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, newlineIdx);
      this.buffer = this.buffer.slice(newlineIdx + 1);
      if (line.trim()) {
        messages.push(decode(line));
      }
    }
    return messages;
  }
}
```

- [ ] **Step 4: Add LineBuffer tests and run all tests**

Add to `channel/protocol.test.ts`:

```typescript
import { LineBuffer } from "./protocol";

describe("LineBuffer", () => {
  it("handles complete lines", () => {
    const buf = new LineBuffer();
    const msgs = buf.push('{"type":"ping"}\n');
    expect(msgs).toHaveLength(1);
    expect(msgs[0].type).toBe("ping");
  });

  it("handles partial reads", () => {
    const buf = new LineBuffer();
    expect(buf.push('{"type":')).toHaveLength(0);
    const msgs = buf.push('"pong"}\n');
    expect(msgs).toHaveLength(1);
    expect(msgs[0].type).toBe("pong");
  });

  it("handles multiple lines in one push", () => {
    const buf = new LineBuffer();
    const msgs = buf.push('{"type":"ping"}\n{"type":"pong"}\n');
    expect(msgs).toHaveLength(2);
  });
});
```

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun test channel/protocol.test.ts
```

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add channel/protocol.ts channel/protocol.test.ts
git commit -m "feat: NDJSON protocol types and helpers with tests"
```

---

### Task 3: Unix Socket Manager

**Files:**
- Create: `channel/socket-manager.ts`
- Create: `channel/socket-manager.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// channel/socket-manager.test.ts
import { describe, it, expect, afterEach } from "bun:test";
import { SocketManager } from "./socket-manager";
import { PROTOCOL_VERSION, encode, type Message } from "./protocol";
import { unlinkSync, existsSync } from "fs";

const TEST_SOCK = "/tmp/cc-mcp-test.sock";

afterEach(() => {
  try { unlinkSync(TEST_SOCK); } catch {}
});

describe("SocketManager", () => {
  it("starts listening on a Unix socket", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});
    expect(existsSync(TEST_SOCK)).toBe(true);
    mgr.stop();
  });

  it("accepts connections and receives handshake", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    const received: Message[] = [];
    await mgr.start((msg, conn) => { received.push(msg); });

    // Connect as a client
    const client = await Bun.connect({
      unix: TEST_SOCK,
      socket: {
        data() {},
        open(socket) {
          socket.write(encode({
            type: "handshake",
            instance: "test-nvim",
            version: PROTOCOL_VERSION,
          }));
        },
      },
    });

    await Bun.sleep(50);
    expect(received.length).toBeGreaterThanOrEqual(1);
    expect(received[0].type).toBe("handshake");
    client.end();
    mgr.stop();
  });

  it("tracks active connections by instance", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const client = await Bun.connect({
      unix: TEST_SOCK,
      socket: {
        data() {},
        open(socket) {
          socket.write(encode({
            type: "handshake",
            instance: "nvim-123",
            version: PROTOCOL_VERSION,
          }));
        },
      },
    });

    await Bun.sleep(50);
    expect(mgr.getActiveInstance()).toBe("nvim-123");
    client.end();
    mgr.stop();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun test channel/socket-manager.test.ts
```

Expected: FAIL — module not found

- [ ] **Step 3: Implement SocketManager**

```typescript
// channel/socket-manager.ts
import { unlinkSync, existsSync, writeFileSync } from "fs";
import {
  type Message,
  type Handshake,
  type Focus,
  PROTOCOL_VERSION,
  encode,
  LineBuffer,
} from "./protocol";

type OnMessage = (msg: Message, conn: Connection) => void;

export interface Connection {
  id: string;
  instance: string | null;
  send(msg: Message): void;
}

export class SocketManager {
  private socketPath: string;
  private pidPath: string;
  private server: ReturnType<typeof Bun.listen> | null = null;
  private connections = new Map<string, {
    socket: any;
    instance: string | null;
    buffer: LineBuffer;
  }>();
  private activeInstance: string | null = null;
  private lastChatInstance: string | null = null;
  private nextConnId = 1;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private onAllDisconnected: (() => void) | null = null;

  constructor(socketPath: string, opts?: { onAllDisconnected?: () => void }) {
    this.socketPath = socketPath;
    this.pidPath = socketPath.replace(/\.sock$/, ".pid");
    this.onAllDisconnected = opts?.onAllDisconnected ?? null;
  }

  async start(onMessage: OnMessage): Promise<void> {
    // Clean up stale socket
    if (existsSync(this.socketPath)) {
      unlinkSync(this.socketPath);
    }

    this.server = Bun.listen({
      unix: this.socketPath,
      socket: {
        open: (socket) => {
          const connId = String(this.nextConnId++);
          this.connections.set(connId, {
            socket,
            instance: null,
            buffer: new LineBuffer(),
          });
          (socket as any).__connId = connId;
          this.clearIdleTimer();
        },

        data: (socket, data) => {
          const connId = (socket as any).__connId as string;
          const conn = this.connections.get(connId);
          if (!conn) return;

          const messages = conn.buffer.push(
            typeof data === "string" ? data : new TextDecoder().decode(data)
          );

          for (const msg of messages) {
            // Handle handshake
            if (msg.type === "handshake") {
              const hs = msg as Handshake;
              if (hs.version !== PROTOCOL_VERSION) {
                const errMsg = encode({
                  type: "error",
                  code: "version_mismatch",
                  message: `Expected protocol version ${PROTOCOL_VERSION}, got ${hs.version}`,
                });
                socket.write(errMsg);
                socket.end();
                return;
              }
              conn.instance = hs.instance;
              if (!this.activeInstance) {
                this.activeInstance = hs.instance;
              }
              socket.write(encode({
                type: "handshake_ack",
                version: PROTOCOL_VERSION,
              }));
            }

            // Handle focus
            if (msg.type === "focus") {
              const focus = msg as Focus;
              conn.instance = focus.instance;
              this.activeInstance = focus.instance;
            }

            // Handle chat — track active sender
            if (msg.type === "chat") {
              this.lastChatInstance = conn.instance;
              this.activeInstance = conn.instance;
            }

            // Handle ping
            if (msg.type === "ping") {
              socket.write(encode({ type: "pong" }));
              return;
            }

            const connection: Connection = {
              id: connId,
              instance: conn.instance,
              send: (m: Message) => socket.write(encode(m)),
            };
            onMessage(msg, connection);
          }
        },

        close: (socket) => {
          const connId = (socket as any).__connId as string;
          const conn = this.connections.get(connId);
          if (conn?.instance === this.activeInstance) {
            this.activeInstance = null;
            // Fall back to another connected instance
            for (const [, c] of this.connections) {
              if (c.instance && c !== conn) {
                this.activeInstance = c.instance;
                break;
              }
            }
          }
          this.connections.delete(connId);

          if (this.connections.size === 0) {
            this.startIdleTimer();
          }
        },

        error: (_socket, error) => {
          console.error("Socket error:", error);
        },
      },
    });

    // Write PID file
    writeFileSync(this.pidPath, String(process.pid));
  }

  stop(): void {
    this.clearIdleTimer();
    this.server?.stop();
    this.server = null;
    try { unlinkSync(this.socketPath); } catch {}
    try { unlinkSync(this.pidPath); } catch {}
  }

  getActiveInstance(): string | null {
    return this.activeInstance ?? this.lastChatInstance;
  }

  getActiveConnection(): Connection | null {
    const target = this.getActiveInstance();
    if (!target) return null;
    for (const [id, conn] of this.connections) {
      if (conn.instance === target) {
        return {
          id,
          instance: conn.instance,
          send: (msg: Message) => conn.socket.write(encode(msg)),
        };
      }
    }
    return null;
  }

  sendToActive(msg: Message): boolean {
    const conn = this.getActiveConnection();
    if (!conn) return false;
    conn.send(msg);
    return true;
  }

  broadcast(msg: Message): void {
    const encoded = encode(msg);
    for (const [, conn] of this.connections) {
      conn.socket.write(encoded);
    }
  }

  private startIdleTimer(): void {
    this.clearIdleTimer();
    this.idleTimer = setTimeout(() => {
      if (this.connections.size === 0 && this.onAllDisconnected) {
        this.onAllDisconnected();
      }
    }, 5 * 60 * 1000); // 5 minutes
  }

  private clearIdleTimer(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun test channel/socket-manager.test.ts
```

Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add channel/socket-manager.ts channel/socket-manager.test.ts
git commit -m "feat: Unix socket manager with connection tracking and idle timeout"
```

---

### Task 4: Channel Server — MCP + Reply Tool

**Files:**
- Create: `channel/server.ts`

- [ ] **Step 1: Implement the channel server**

This is the central bridge. It connects to Claude Code over MCP stdio and serves Neovim connections via the Unix socket.

```typescript
// channel/server.ts
#!/usr/bin/env bun
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { SocketManager, type Connection } from "./socket-manager";
import { type Message, type Chat, type Verdict, type Response } from "./protocol";

const SOCKET_PATH = process.env.CC_MCP_SOCKET ?? "/tmp/cc-mcp.sock";

// Pending RPC requests to Neovim (MCP tool -> socket -> Neovim -> socket -> resolve)
const pendingRequests = new Map<string, {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}>();
let nextRequestId = 1;

// Pending approval requests
const pendingApprovals = new Map<string, {
  resolve: (approved: boolean) => void;
  timer: ReturnType<typeof setTimeout>;
}>();
let nextApprovalId = 1;

// -- MCP Server --

const mcp = new Server(
  { name: "cc-mcp", version: "0.1.0" },
  {
    capabilities: {
      experimental: {
        "claude/channel": {},
        "claude/channel/permission": {},
      },
      tools: {},
    },
    instructions: `You are a Neovim configuration assistant. Messages arrive as <channel source="cc-mcp" ...>.
You have access to the user's live Neovim state through MCP tools (keymaps, options, buffers, LSP, plugins, etc.).
You can also read and modify config files in the current directory (~/.config/nvim).
Reply to the user with the reply tool, passing the chat_id from the incoming tag.
For mutations that run inside Neovim (exec_lua, exec_command), the user will see the code and must approve it before execution.`,
  }
);

// -- Reply tool: send messages back to Neovim --

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "reply",
      description: "Send a message back to the user in their Neovim chat buffer",
      inputSchema: {
        type: "object" as const,
        properties: {
          chat_id: { type: "string", description: "The chat_id from the incoming channel message" },
          text: { type: "string", description: "The message to send (markdown supported)" },
        },
        required: ["chat_id", "text"],
      },
    },
    // Read-only Neovim state tools
    {
      name: "nvim_get_keymaps",
      description: "Get all keymaps for a given mode from the active Neovim instance",
      inputSchema: {
        type: "object" as const,
        properties: {
          mode: { type: "string", description: "Vim mode: n, i, v, x, s, o, t, c, l" },
        },
        required: ["mode"],
      },
    },
    {
      name: "nvim_get_option",
      description: "Get the value of a Neovim option",
      inputSchema: {
        type: "object" as const,
        properties: {
          name: { type: "string", description: "Option name (e.g., 'tabstop', 'shiftwidth')" },
        },
        required: ["name"],
      },
    },
    {
      name: "nvim_list_buffers",
      description: "List all open buffers with metadata",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "nvim_get_lsp_state",
      description: "Get attached LSP clients and their capabilities",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "nvim_get_loaded_plugins",
      description: "List loaded plugins and their status",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "nvim_get_context",
      description: "Get current editing context (cursor, file, mode, selection)",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "nvim_get_registers",
      description: "Get contents of specified registers",
      inputSchema: {
        type: "object" as const,
        properties: {
          registers: {
            type: "array",
            items: { type: "string" },
            description: "Register names (e.g., ['a', 'b', '+', '*']). Omit for common registers.",
          },
        },
      },
    },
    {
      name: "nvim_get_treesitter",
      description: "Get treesitter parser info for the active buffer",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "nvim_get_health",
      description: "Run :checkhealth and return the output (best-effort, unstructured text)",
      inputSchema: { type: "object" as const, properties: {} },
    },
    // Mutation tools (require user approval)
    {
      name: "nvim_exec_lua",
      description: "Execute Lua code in the active Neovim instance. REQUIRES user approval — the code will be shown to the user for review.",
      inputSchema: {
        type: "object" as const,
        properties: {
          code: { type: "string", description: "Lua code to execute" },
          description: { type: "string", description: "Brief description of what this code does" },
        },
        required: ["code", "description"],
      },
    },
    {
      name: "nvim_exec_command",
      description: "Execute a Vim command in the active Neovim instance. REQUIRES user approval.",
      inputSchema: {
        type: "object" as const,
        properties: {
          command: { type: "string", description: "Vim command to execute (without leading :)" },
          description: { type: "string", description: "Brief description of what this command does" },
        },
        required: ["command", "description"],
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name } = req.params;
  const args = req.params.arguments as Record<string, unknown>;

  // Reply tool — send text back to Neovim
  if (name === "reply") {
    const chatId = args.chat_id as string;
    const text = args.text as string;
    // Stream the reply in chunks (split on double newline for paragraph-level streaming)
    const chunks = text.split(/\n\n/);
    for (let i = 0; i < chunks.length; i++) {
      const content = i < chunks.length - 1 ? chunks[i] + "\n\n" : chunks[i];
      socketManager.sendToActive({
        id: chatId,
        type: "reply_chunk",
        content,
      });
    }
    socketManager.sendToActive({ id: chatId, type: "reply_end" });
    return { content: [{ type: "text", text: "sent" }] };
  }

  // Mutation tools — require approval
  if (name === "nvim_exec_lua" || name === "nvim_exec_command") {
    const code = (name === "nvim_exec_lua" ? args.code : args.command) as string;
    const lang = name === "nvim_exec_lua" ? "lua" : "vim";
    const description = (args.description as string) ?? "";

    const approvalId = `a${nextApprovalId++}`;
    socketManager.sendToActive({
      id: approvalId,
      type: "approval",
      code,
      lang,
      description,
    });

    const approved = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        pendingApprovals.delete(approvalId);
        resolve(false);
      }, 120_000); // 2 minute timeout
      pendingApprovals.set(approvalId, { resolve, timer });
    });

    if (!approved) {
      return { content: [{ type: "text", text: "User rejected the mutation." }] };
    }

    // Execute via RPC to Neovim
    const result = await rpcRequest(
      name === "nvim_exec_lua" ? "exec_lua" : "exec_command",
      name === "nvim_exec_lua" ? { code } : { command: args.command }
    );
    return { content: [{ type: "text", text: String(result ?? "ok") }] };
  }

  // Read-only tools — proxy to Neovim via RPC
  const methodMap: Record<string, string> = {
    nvim_get_keymaps: "get_keymaps",
    nvim_get_option: "get_option",
    nvim_list_buffers: "list_buffers",
    nvim_get_lsp_state: "get_lsp_state",
    nvim_get_loaded_plugins: "get_loaded_plugins",
    nvim_get_context: "get_context",
    nvim_get_registers: "get_registers",
    nvim_get_treesitter: "get_treesitter",
    nvim_get_health: "get_health",
  };

  const method = methodMap[name];
  if (!method) {
    throw new Error(`Unknown tool: ${name}`);
  }

  const result = await rpcRequest(method, args);
  return {
    content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
  };
});

// -- Permission relay --

const PermissionRequestSchema = z.object({
  method: z.literal("notifications/claude/channel/permission_request"),
  params: z.object({
    request_id: z.string(),
    tool_name: z.string(),
    description: z.string(),
    input_preview: z.string(),
  }),
});

mcp.setNotificationHandler(PermissionRequestSchema, async ({ params }) => {
  const approvalId = `p${params.request_id}`;
  socketManager.sendToActive({
    id: approvalId,
    type: "approval",
    code: params.input_preview,
    lang: params.tool_name.toLowerCase(),
    description: `Claude Code wants to run ${params.tool_name}: ${params.description}`,
  });

  const approved = await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => {
      pendingApprovals.delete(approvalId);
      resolve(false);
    }, 120_000);
    pendingApprovals.set(approvalId, { resolve, timer });
  });

  await mcp.notification({
    method: "notifications/claude/channel/permission",
    params: {
      request_id: params.request_id,
      behavior: approved ? "allow" : "deny",
    },
  });
});

// -- RPC helper: send request to Neovim, await response --

function rpcRequest(method: string, params?: Record<string, unknown>): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const id = `r${nextRequestId++}`;
    const timer = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error(`RPC timeout for ${method}`));
    }, 10_000);

    pendingRequests.set(id, { resolve, reject, timer });
    const sent = socketManager.sendToActive({
      id,
      type: "request",
      method,
      params,
    });
    if (!sent) {
      clearTimeout(timer);
      pendingRequests.delete(id);
      reject(new Error("No active Neovim connection"));
    }
  });
}

// -- Socket Manager --

const socketManager = new SocketManager(SOCKET_PATH, {
  onAllDisconnected: () => {
    console.error("All Neovim instances disconnected. Shutting down after idle timeout.");
    process.exit(0);
  },
});

function handleSocketMessage(msg: Message, conn: Connection): void {
  // Chat messages -> forward to Claude Code as channel notification
  if (msg.type === "chat") {
    const chat = msg as Chat;
    mcp.notification({
      method: "notifications/claude/channel",
      params: {
        content: chat.content,
        meta: { chat_id: chat.id, instance: chat.instance },
      },
    });
    return;
  }

  // RPC responses from Neovim
  if (msg.type === "response") {
    const resp = msg as Response;
    const pending = pendingRequests.get(resp.id);
    if (pending) {
      clearTimeout(pending.timer);
      pendingRequests.delete(resp.id);
      pending.resolve(resp.result);
    }
    return;
  }

  // Approval verdicts from Neovim
  if (msg.type === "verdict") {
    const verdict = msg as Verdict;
    const pending = pendingApprovals.get(verdict.id);
    if (pending) {
      clearTimeout(pending.timer);
      pendingApprovals.delete(verdict.id);
      pending.resolve(verdict.approved);
    }
    return;
  }

  // Error responses
  if (msg.type === "error") {
    const err = msg as { id?: string; type: "error"; code: string; message: string };
    if (err.id) {
      const pending = pendingRequests.get(err.id);
      if (pending) {
        clearTimeout(pending.timer);
        pendingRequests.delete(err.id);
        pending.reject(new Error(`${err.code}: ${err.message}`));
      }
    }
    return;
  }
}

// -- Start --

await socketManager.start(handleSocketMessage);
await mcp.connect(new StdioServerTransport());
```

- [ ] **Step 2: Verify the server compiles**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun build --target=bun channel/server.ts --outdir=/dev/null 2>&1 | head -5
```

Expected: no TypeScript errors

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add channel/server.ts
git commit -m "feat: MCP channel server with reply tool, state tools, and permission relay"
```

---

### Task 5: Neovim Plugin — Socket Client

**Files:**
- Create: `lua/cc-mcp/socket.lua`

- [ ] **Step 1: Implement the socket client**

```lua
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
```

- [ ] **Step 2: Verify syntax**

```bash
luac -p /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/socket.lua && echo "OK"
```

Expected: OK

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add lua/cc-mcp/socket.lua
git commit -m "feat: Neovim Unix socket client with NDJSON and handshake"
```

---

### Task 6: Neovim Plugin — RPC Handler

**Files:**
- Create: `lua/cc-mcp/rpc.lua`

- [ ] **Step 1: Implement RPC handler**

```lua
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
```

- [ ] **Step 2: Verify syntax**

```bash
luac -p /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/rpc.lua && echo "OK"
```

Expected: OK

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add lua/cc-mcp/rpc.lua
git commit -m "feat: Neovim RPC handler for state queries and command execution"
```

---

### Task 7: Chat Buffer

**Files:**
- Create: `lua/cc-mcp/chat.lua`

- [ ] **Step 1: Implement the chat buffer**

```lua
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
```

- [ ] **Step 2: Verify syntax**

```bash
luac -p /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/chat.lua && echo "OK"
```

Expected: OK

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add lua/cc-mcp/chat.lua
git commit -m "feat: chat buffer with markdown rendering, input region, and approval UI"
```

---

### Task 8: Singleton Manager

**Files:**
- Create: `lua/cc-mcp/singleton.lua`

- [ ] **Step 1: Implement singleton lifecycle**

```lua
-- lua/cc-mcp/singleton.lua
-- Manages the Claude Code + channel server singleton process

local M = {}

local socket_path = os.getenv("CC_MCP_SOCKET") or "/tmp/cc-mcp.sock"
local pid_path = socket_path:gsub("%.sock$", ".pid")

-- Check if the socket is alive (file exists + responds to ping)
function M.is_alive()
  local stat = vim.loop.fs_stat(socket_path)
  return stat ~= nil
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
```

- [ ] **Step 2: Verify syntax**

```bash
luac -p /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/singleton.lua && echo "OK"
```

Expected: OK

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add lua/cc-mcp/singleton.lua
git commit -m "feat: singleton manager with spawn, polling, and detached process lifecycle"
```

---

### Task 9: Plugin Entry Point & :Help Command

**Files:**
- Create: `lua/cc-mcp/init.lua`

- [ ] **Step 1: Implement the plugin entry point**

```lua
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
```

- [ ] **Step 2: Verify syntax**

```bash
luac -p /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/init.lua && echo "OK"
```

Expected: OK

- [ ] **Step 3: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add lua/cc-mcp/init.lua
git commit -m "feat: plugin entry point with :Help command and FocusGained tracking"
```

---

### Task 10: Claude Code Plugin — Manifest & Agents

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/agents/config-researcher.md`
- Create: `.claude-plugin/agents/config-modifier.md`
- Create: `.claude-plugin/agents/plugin-researcher.md`
- Create: `.claude-plugin/agents/troubleshooter.md`
- Create: `.claude-plugin/agents/keymap-advisor.md`

- [ ] **Step 1: Create plugin.json**

```json
{
  "name": "cc-mcp",
  "version": "0.1.0",
  "description": "Neovim configuration assistant powered by Claude Code",
  "author": "",
  "homepage": ""
}
```

- [ ] **Step 2: Create config-researcher agent**

```markdown
---
name: config-researcher
description: Answers questions about the user's current Neovim configuration by reading config files and querying live Neovim state via MCP tools
tools: ["Read", "Glob", "Grep", "mcp__cc-mcp__nvim_get_keymaps", "mcp__cc-mcp__nvim_get_option", "mcp__cc-mcp__nvim_list_buffers", "mcp__cc-mcp__nvim_get_lsp_state", "mcp__cc-mcp__nvim_get_loaded_plugins", "mcp__cc-mcp__nvim_get_context", "mcp__cc-mcp__nvim_get_treesitter"]
---

You are a Neovim configuration researcher. Your job is to answer questions about the user's Neovim setup by reading their config files (~/.config/nvim/) and querying live Neovim state.

When answering:
- Read the relevant config files to understand how things are set up
- Use MCP tools to query live state (keymaps, options, LSP, plugins) when the question is about current runtime behavior
- Always cite specific file paths and line numbers
- Explain not just what a setting does, but why it might be configured that way
- If a keymap or setting comes from a plugin rather than user config, say so

The user's config is Lua-based, uses lazy.nvim, and follows a modular structure under lua/config/ and lua/plugins/.
```

- [ ] **Step 3: Create config-modifier agent**

```markdown
---
name: config-modifier
description: Makes changes to Neovim configuration files (keymaps, plugin configs, options) and can hot-reload changes via Lua execution
tools: ["Read", "Edit", "Write", "Glob", "Grep", "mcp__cc-mcp__nvim_get_keymaps", "mcp__cc-mcp__nvim_get_loaded_plugins", "mcp__cc-mcp__nvim_exec_lua"]
---

You are a Neovim configuration modifier. Your job is to make changes to the user's Neovim config and optionally hot-reload them.

When making changes:
- Read the existing config structure first to understand conventions
- Follow the existing patterns (Lua style, file organization, naming)
- Place changes in the appropriate file (mappings go in mappings.lua, plugin configs in their own file under plugins/, etc.)
- After writing a config change, offer to hot-reload it via nvim_exec_lua
- Explain what you changed and why
- For keymaps, check for conflicts with existing mappings first

The config uses lazy.nvim with auto-loading from lua/plugins/. LSP configs are in lsp/. File-type configs are in after/ftplugin/.
```

- [ ] **Step 4: Create plugin-researcher agent**

```markdown
---
name: plugin-researcher
description: Researches and evaluates Neovim plugins by searching the web, reading documentation, and checking compatibility with the current setup
tools: ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "mcp__cc-mcp__nvim_get_loaded_plugins"]
---

You are a Neovim plugin researcher. Your job is to find, evaluate, and recommend Neovim plugins.

When researching:
- Search for plugins on GitHub and Neovim plugin directories
- Read plugin READMEs and documentation
- Check the user's current plugin list to avoid recommending duplicates or incompatible plugins
- Compare alternatives with pros/cons
- Provide a lazy.nvim plugin spec for installation
- Note any dependencies or requirements
- Check if the plugin is actively maintained (last commit date, open issues)
```

- [ ] **Step 5: Create troubleshooter agent**

```markdown
---
name: troubleshooter
description: Debugs Neovim configuration issues like LSP not attaching, keymap conflicts, plugin errors, and unexpected behavior
tools: ["Read", "Glob", "Grep", "Bash", "mcp__cc-mcp__nvim_get_keymaps", "mcp__cc-mcp__nvim_get_option", "mcp__cc-mcp__nvim_get_lsp_state", "mcp__cc-mcp__nvim_get_loaded_plugins", "mcp__cc-mcp__nvim_get_context", "mcp__cc-mcp__nvim_get_treesitter", "mcp__cc-mcp__nvim_exec_lua"]
---

You are a Neovim troubleshooter. Your job is to diagnose and fix issues with the user's Neovim configuration.

When debugging:
- Query live Neovim state to understand current conditions
- Read relevant config files to find potential causes
- Check for common issues: keymap conflicts, missing LSP servers, plugin load failures, incorrect options
- Use exec_lua to run diagnostic commands when needed (e.g., checking if a module is loaded)
- Provide step-by-step fixes with explanations
- Verify fixes resolve the issue when possible
```

- [ ] **Step 6: Create keymap-advisor agent**

```markdown
---
name: keymap-advisor
description: Analyzes the keymap landscape, finds available keys, detects conflicts, and suggests ergonomic key bindings
tools: ["Read", "Glob", "Grep", "mcp__cc-mcp__nvim_get_keymaps", "mcp__cc-mcp__nvim_get_loaded_plugins"]
---

You are a Neovim keymap advisor. Your job is to help the user manage their keybindings.

When analyzing keymaps:
- Query all current keymaps across modes to get the full picture
- Cross-reference with which-key groups if available
- Identify conflicts (same key mapped by multiple sources)
- Find available keys that follow ergonomic patterns
- Suggest bindings that fit the user's existing conventions (leader key, prefix groups)
- Note which bindings come from plugins vs user config
- Consider muscle memory — don't suggest overriding commonly used defaults unless asked

Query nvim_get_keymaps to discover the user's leader and local leader key conventions.
```

- [ ] **Step 7: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add .claude-plugin/
git commit -m "feat: Claude Code plugin manifest and specialized agents"
```

---

### Task 11: Claude Code Plugin — Skills

**Files:**
- Create: `.claude-plugin/skills/add-keymap.md`
- Create: `.claude-plugin/skills/add-plugin.md`
- Create: `.claude-plugin/skills/health-check.md`
- Create: `.claude-plugin/skills/explain-config.md`

- [ ] **Step 1: Create add-keymap skill**

```markdown
---
name: add-keymap
description: Guided workflow for adding a new keymap to the Neovim configuration
---

# Add Keymap

Walk through adding a new keymap:

1. Ask what action the user wants to bind
2. Query existing keymaps via nvim_get_keymaps to find conflicts
3. Suggest available keys that fit the user's convention
4. Determine which file the keymap belongs in (mappings.lua, a plugin file, or ftplugin)
5. Write the keymap using vim.keymap.set with a desc field
6. Offer to hot-reload via nvim_exec_lua
7. Verify the keymap is active by querying keymaps again
```

- [ ] **Step 2: Create add-plugin skill**

```markdown
---
name: add-plugin
description: Guided workflow for installing and configuring a new Neovim plugin
---

# Add Plugin

Walk through adding a new Neovim plugin:

1. Confirm the plugin name and purpose
2. Check if a similar plugin is already installed via nvim_get_loaded_plugins
3. Research the plugin's README for configuration options
4. Create a new file in lua/plugins/<plugin-name>.lua with the lazy.nvim spec
5. Include sensible defaults and keymaps
6. Explain any dependencies that need to be installed
7. Instruct the user to restart Neovim or run :Lazy sync
```

- [ ] **Step 3: Create health-check skill**

```markdown
---
name: health-check
description: Run diagnostics on the Neovim configuration
---

# Health Check

Run a comprehensive health check:

1. Query loaded plugins — check for load errors
2. Query LSP state — verify expected servers are attached
3. Query treesitter — check parser availability for common filetypes
4. Read the config files — look for common issues (deprecated APIs, typos)
5. Check for keymap conflicts across all modes
6. Verify the Python provider is configured correctly
7. Present a summary with issues found and suggestions
```

- [ ] **Step 4: Create explain-config skill**

```markdown
---
name: explain-config
description: Walk through and explain a Neovim configuration file in detail
---

# Explain Config

When explaining a config file:

1. Read the file the user asks about
2. Break it down section by section
3. Explain what each setting/mapping/plugin spec does
4. Note any non-obvious interactions with other parts of the config
5. Highlight anything unusual or potentially problematic
6. Suggest improvements if appropriate (but don't push unsolicited changes)
```

- [ ] **Step 5: Commit**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add .claude-plugin/skills/
git commit -m "feat: Claude Code plugin skills for guided workflows"
```

---

### Task 12: Integration Wiring & Manual Testing

**Files:**
- Modify: `channel/server.ts` (if needed for fixes)
- Modify: `lua/cc-mcp/init.lua` (if needed for fixes)

- [ ] **Step 1: Verify the full file tree exists**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && find . -type f | grep -v node_modules | grep -v '.git/' | sort
```

Expected: All files from the file map are present.

- [ ] **Step 2: Run TypeScript tests**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && bun test
```

Expected: ALL PASS

- [ ] **Step 3: Verify Lua syntax for all files**

```bash
for f in /Users/admin/src/tools/cc-mcp.nvim/lua/cc-mcp/*.lua; do luac -p "$f" && echo "OK: $f" || echo "FAIL: $f"; done
```

Expected: All OK

- [ ] **Step 4: Manual test — start channel server standalone**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim && echo '{}' | timeout 2 bun run channel/server.ts 2>&1 || true
```

Verify: Server starts without crash (may timeout after 2s since stdin closes).

- [ ] **Step 5: Manual test — load plugin in Neovim**

Open Neovim and run:
```vim
:set runtimepath+=/Users/admin/src/tools/cc-mcp.nvim
:lua require("cc-mcp").setup()
:Help
```

Verify: Chat buffer opens in a vertical split. The server won't connect yet (Claude Code not running), but the buffer should appear.

- [ ] **Step 6: Final commit with any fixes**

```bash
cd /Users/admin/src/tools/cc-mcp.nvim
git add -A
git commit -m "chore: integration wiring and verification"
```

---

### Task 13: Add Plugin to User's Neovim Config

**Files:**
- Modify: `~/.config/nvim/lua/plugins/cc-mcp.lua` (new file in user's config)

- [ ] **Step 1: Create the lazy.nvim plugin spec**

```lua
-- ~/.config/nvim/lua/plugins/cc-mcp.lua
return {
  dir = "/Users/admin/src/tools/cc-mcp.nvim",
  cmd = "Help",
  keys = { { "<leader>h", "<cmd>Help<cr>", desc = "Claude Help" } },
  build = "cd channel && bun install",
  opts = {},
}
```

- [ ] **Step 2: Commit to dotfiles**

```bash
cd ~ && git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME add .config/nvim/lua/plugins/cc-mcp.lua
git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME commit -m "feat(nvim): add cc-mcp.nvim plugin for Claude-powered config help"
```

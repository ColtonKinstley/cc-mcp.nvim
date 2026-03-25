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

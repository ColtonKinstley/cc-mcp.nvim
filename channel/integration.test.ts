/**
 * Full integration test: spawns the channel server, connects as both
 * an MCP client (simulating Claude Code) and a socket client (simulating Neovim),
 * and tests the actual message flow end-to-end.
 */
import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { encode, decode, PROTOCOL_VERSION, type Message } from "./protocol";
import { Subprocess } from "bun";
import { unlinkSync, existsSync } from "fs";

const TEST_SOCK = "/tmp/cc-mcp-integ.sock";
const JSONRPC = "2.0";

let server: Subprocess;
let mcpBuffer = ""; // accumulated stdout from server (MCP responses)
let mcpMessages: any[] = [];

// Parse NDJSON lines from MCP stdout
function parseMcpBuffer(data: string) {
  mcpBuffer += data;
  let idx: number;
  while ((idx = mcpBuffer.indexOf("\n")) !== -1) {
    const line = mcpBuffer.slice(0, idx).trim();
    mcpBuffer = mcpBuffer.slice(idx + 1);
    if (line) {
      try {
        mcpMessages.push(JSON.parse(line));
      } catch {}
    }
  }
}

// Send a JSON-RPC message to the server's stdin (as Claude Code would)
function mcpSend(msg: any) {
  server.stdin.write(JSON.stringify(msg) + "\n");
}

// Wait for an MCP message matching a predicate
async function waitForMcp(
  pred: (msg: any) => boolean,
  timeoutMs = 3000
): Promise<any> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = mcpMessages.find(pred);
    if (found) return found;
    await Bun.sleep(50);
  }
  throw new Error("Timed out waiting for MCP message");
}

// Connect a fake Neovim client via Unix socket
async function connectNvim(instance: string) {
  const received: Message[] = [];
  const socket = await Bun.connect({
    unix: TEST_SOCK,
    socket: {
      data(_socket, data) {
        const text = typeof data === "string" ? data : new TextDecoder().decode(data);
        // Parse NDJSON
        for (const line of text.split("\n")) {
          if (line.trim()) {
            try { received.push(decode(line)); } catch {}
          }
        }
      },
      open(socket) {
        socket.write(
          encode({
            type: "handshake",
            instance,
            version: PROTOCOL_VERSION,
          })
        );
      },
    },
  });
  return { socket, received };
}

beforeAll(async () => {
  // Clean up stale files
  try { unlinkSync(TEST_SOCK); } catch {}

  // Spawn channel server
  server = Bun.spawn(["bun", "run", "channel/server.ts"], {
    env: { ...process.env, CC_MCP_SOCKET: TEST_SOCK },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  // Read stdout asynchronously
  const reader = server.stdout.getReader();
  const decoder = new TextDecoder();
  (async () => {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      parseMcpBuffer(decoder.decode(value));
    }
  })();

  // Wait for socket to appear
  for (let i = 0; i < 40; i++) {
    if (existsSync(TEST_SOCK)) break;
    await Bun.sleep(50);
  }
  if (!existsSync(TEST_SOCK)) throw new Error("Server did not create socket");

  // MCP handshake: initialize
  mcpSend({
    jsonrpc: JSONRPC,
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "test-client", version: "1.0.0" },
    },
  });

  // Wait for initialize response
  await waitForMcp((m) => m.id === 1 && m.result);

  // Send initialized notification
  mcpSend({
    jsonrpc: JSONRPC,
    method: "notifications/initialized",
    params: {},
  });

  await Bun.sleep(100);
});

afterAll(() => {
  server?.kill();
  try { unlinkSync(TEST_SOCK); } catch {}
  try { unlinkSync(TEST_SOCK.replace(".sock", ".pid")); } catch {}
});

describe("Integration: MCP + Socket", () => {
  it("MCP initialize returns server info and tools capability", async () => {
    const initResp = mcpMessages.find((m) => m.id === 1 && m.result);
    expect(initResp).toBeTruthy();
    expect(initResp.result.serverInfo.name).toBe("cc-mcp");
    expect(initResp.result.capabilities.tools).toBeTruthy();
  });

  it("MCP tools/list returns all expected tools", async () => {
    mcpSend({
      jsonrpc: JSONRPC,
      id: 10,
      method: "tools/list",
      params: {},
    });

    const resp = await waitForMcp((m) => m.id === 10 && m.result);
    const toolNames = resp.result.tools.map((t: any) => t.name);

    expect(toolNames).toContain("reply");
    expect(toolNames).toContain("nvim_get_keymaps");
    expect(toolNames).toContain("nvim_get_option");
    expect(toolNames).toContain("nvim_list_buffers");
    expect(toolNames).toContain("nvim_get_lsp_state");
    expect(toolNames).toContain("nvim_get_loaded_plugins");
    expect(toolNames).toContain("nvim_get_context");
    expect(toolNames).toContain("nvim_get_registers");
    expect(toolNames).toContain("nvim_get_treesitter");
    expect(toolNames).toContain("nvim_get_health");
    expect(toolNames).toContain("nvim_exec_lua");
    expect(toolNames).toContain("nvim_exec_command");
    expect(toolNames.length).toBe(12);
  });

  it("Neovim connects and gets handshake_ack", async () => {
    const { socket, received } = await connectNvim("nvim-integ-1");
    await Bun.sleep(100);

    expect(received.length).toBeGreaterThanOrEqual(1);
    expect(received[0].type).toBe("handshake_ack");

    socket.end();
  });

  it("chat message from Neovim arrives as MCP channel notification", async () => {
    const { socket, received } = await connectNvim("nvim-integ-2");
    await Bun.sleep(100);

    // Clear previous MCP messages
    const prevCount = mcpMessages.length;

    // Send a chat message as Neovim would
    socket.write(
      encode({
        id: "m1",
        type: "chat",
        instance: "nvim-integ-2",
        content: "What does <leader>d do?",
      })
    );

    // Wait for the MCP notification to appear
    const notification = await waitForMcp(
      (m) =>
        !m.id &&
        m.method === "notifications/claude/channel" &&
        mcpMessages.indexOf(m) >= prevCount
    );

    expect(notification.params.content).toBe("What does <leader>d do?");
    expect(notification.params.meta.chat_id).toBe("m1");
    expect(notification.params.meta.instance).toBe("nvim-integ-2");

    socket.end();
  });

  it("reply tool sends chunks and end to Neovim", async () => {
    const { socket, received } = await connectNvim("nvim-integ-3");
    await Bun.sleep(100);
    received.length = 0; // clear handshake_ack

    // Call the reply tool via MCP (as Claude Code would)
    mcpSend({
      jsonrpc: JSONRPC,
      id: 20,
      method: "tools/call",
      params: {
        name: "reply",
        arguments: {
          chat_id: "m1",
          text: "First paragraph.\n\nSecond paragraph.",
        },
      },
    });

    // Wait for reply to arrive at Neovim socket
    await Bun.sleep(200);

    // Should have received reply_chunk(s) + reply_end
    const chunks = received.filter((m) => m.type === "reply_chunk");
    const ends = received.filter((m) => m.type === "reply_end");

    expect(chunks.length).toBeGreaterThanOrEqual(1);
    expect(ends.length).toBe(1);

    // Content should contain the full text
    const fullText = chunks.map((c: any) => c.content).join("");
    expect(fullText).toContain("First paragraph.");
    expect(fullText).toContain("Second paragraph.");

    // MCP should get success response
    const mcpResp = await waitForMcp((m) => m.id === 20 && m.result);
    expect(mcpResp.result.content[0].text).toBe("sent");

    socket.end();
  });

  it("RPC request from MCP tool reaches Neovim and gets response", async () => {
    const { socket, received } = await connectNvim("nvim-integ-4");
    await Bun.sleep(100);
    received.length = 0;

    // Call nvim_get_keymaps via MCP — this should send an RPC request to Neovim
    mcpSend({
      jsonrpc: JSONRPC,
      id: 30,
      method: "tools/call",
      params: {
        name: "nvim_get_keymaps",
        arguments: { mode: "n" },
      },
    });

    // Wait for RPC request to arrive at Neovim
    await Bun.sleep(200);
    const rpcReq = received.find((m) => m.type === "request");
    expect(rpcReq).toBeTruthy();
    expect((rpcReq as any).method).toBe("get_keymaps");

    // Respond as Neovim would
    socket.write(
      encode({
        id: (rpcReq as any).id,
        type: "response",
        result: [{ lhs: "<leader>d", rhs: "definition", mode: "n" }],
      })
    );

    // Wait for MCP to relay the response back
    const mcpResp = await waitForMcp((m) => m.id === 30 && m.result);
    expect(mcpResp.result.content[0].text).toContain("<leader>d");

    socket.end();
  });

  it("approval flow: mutation tool sends approval, receives verdict", async () => {
    const { socket, received } = await connectNvim("nvim-integ-5");
    await Bun.sleep(100);
    received.length = 0;

    // Call nvim_exec_lua via MCP — should send approval request to Neovim
    mcpSend({
      jsonrpc: JSONRPC,
      id: 40,
      method: "tools/call",
      params: {
        name: "nvim_exec_lua",
        arguments: {
          code: 'vim.keymap.set("n", "<leader>t", ":terminal<CR>")',
          description: "Add terminal toggle keymap",
        },
      },
    });

    // Wait for approval request at Neovim
    await Bun.sleep(200);
    const approval = received.find((m) => m.type === "approval");
    expect(approval).toBeTruthy();
    expect((approval as any).lang).toBe("lua");
    expect((approval as any).description).toBe("Add terminal toggle keymap");
    expect((approval as any).code).toContain("vim.keymap.set");

    // Approve it (as user would press Enter in chat buffer)
    socket.write(
      encode({
        id: (approval as any).id,
        type: "verdict",
        approved: true,
      })
    );

    // After approval, server sends RPC to execute the code
    await Bun.sleep(200);
    const execReq = received.find((m) => m.type === "request" && (m as any).method === "exec_lua");
    expect(execReq).toBeTruthy();

    // Respond with success
    socket.write(
      encode({
        id: (execReq as any).id,
        type: "response",
        result: { result: null },
      })
    );

    // MCP should get success
    const mcpResp = await waitForMcp((m) => m.id === 40 && m.result);
    expect(mcpResp.result.content[0].text).toBeTruthy();

    socket.end();
  });

  it("rejected mutation returns rejection message to MCP", async () => {
    const { socket, received } = await connectNvim("nvim-integ-6");
    await Bun.sleep(100);
    received.length = 0;

    mcpSend({
      jsonrpc: JSONRPC,
      id: 50,
      method: "tools/call",
      params: {
        name: "nvim_exec_command",
        arguments: {
          command: "set number",
          description: "Enable line numbers",
        },
      },
    });

    await Bun.sleep(200);
    const approval = received.find((m) => m.type === "approval");
    expect(approval).toBeTruthy();

    // Reject
    socket.write(
      encode({
        id: (approval as any).id,
        type: "verdict",
        approved: false,
      })
    );

    const mcpResp = await waitForMcp((m) => m.id === 50 && m.result);
    expect(mcpResp.result.content[0].text).toContain("rejected");

    socket.end();
  });
});

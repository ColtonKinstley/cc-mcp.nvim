import { describe, it, expect, afterEach } from "bun:test";
import { SocketManager } from "./socket-manager";
import { PROTOCOL_VERSION, encode, decode, type Message } from "./protocol";
import { unlinkSync, existsSync, readFileSync } from "fs";

const TEST_SOCK = "/tmp/cc-mcp-test.sock";
const TEST_PID = "/tmp/cc-mcp-test.pid";

afterEach(() => {
  try { unlinkSync(TEST_SOCK); } catch {}
  try { unlinkSync(TEST_PID); } catch {}
});

// Helper: connect a client and optionally send handshake
async function connectClient(sock: string, instance: string) {
  const receivedData: string[] = [];
  const client = await Bun.connect({
    unix: sock,
    socket: {
      data(_socket, data) {
        receivedData.push(typeof data === "string" ? data : new TextDecoder().decode(data));
      },
      open(socket) {
        socket.write(encode({
          type: "handshake",
          instance,
          version: PROTOCOL_VERSION,
        }));
      },
    },
  });
  return { client, receivedData };
}

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

    const { client } = await connectClient(TEST_SOCK, "nvim-123");

    await Bun.sleep(50);
    expect(mgr.getActiveInstance()).toBe("nvim-123");
    client.end();
    mgr.stop();
  });

  it("writes PID file on start", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});
    expect(existsSync(TEST_PID)).toBe(true);
    const pid = readFileSync(TEST_PID, "utf-8").trim();
    expect(Number(pid)).toBe(process.pid);
    mgr.stop();
  });

  it("cleans up socket and PID on stop", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});
    expect(existsSync(TEST_SOCK)).toBe(true);
    expect(existsSync(TEST_PID)).toBe(true);
    mgr.stop();
    expect(existsSync(TEST_SOCK)).toBe(false);
    expect(existsSync(TEST_PID)).toBe(false);
  });

  it("sends handshake_ack on valid handshake", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client, receivedData } = await connectClient(TEST_SOCK, "nvim-ack");

    await Bun.sleep(50);
    const ack = decode(receivedData[0]);
    expect(ack.type).toBe("handshake_ack");
    expect((ack as any).version).toBe(PROTOCOL_VERSION);
    client.end();
    mgr.stop();
  });

  it("rejects handshake with wrong version", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const receivedData: string[] = [];
    const client = await Bun.connect({
      unix: TEST_SOCK,
      socket: {
        data(_socket, data) {
          receivedData.push(typeof data === "string" ? data : new TextDecoder().decode(data));
        },
        open(socket) {
          socket.write(encode({
            type: "handshake",
            instance: "bad-client",
            version: "999",
          }));
        },
      },
    });

    await Bun.sleep(50);
    expect(receivedData.length).toBeGreaterThanOrEqual(1);
    const err = decode(receivedData[0]);
    expect(err.type).toBe("error");
    expect((err as any).code).toBe("version_mismatch");
    client.end();
    mgr.stop();
  });

  it("updates active instance on focus message", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client: c1 } = await connectClient(TEST_SOCK, "nvim-1");
    const { client: c2 } = await connectClient(TEST_SOCK, "nvim-2");
    await Bun.sleep(50);

    // nvim-2 connected last but let's send focus from nvim-1
    c1.write(encode({ type: "focus", instance: "nvim-1" }));
    await Bun.sleep(50);
    expect(mgr.getActiveInstance()).toBe("nvim-1");

    c1.end();
    c2.end();
    mgr.stop();
  });

  it("falls back to another instance when active disconnects", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client: c1 } = await connectClient(TEST_SOCK, "nvim-1");
    await Bun.sleep(50);
    const { client: c2 } = await connectClient(TEST_SOCK, "nvim-2");
    await Bun.sleep(50);

    // Focus on nvim-2
    c2.write(encode({ type: "focus", instance: "nvim-2" }));
    await Bun.sleep(50);
    expect(mgr.getActiveInstance()).toBe("nvim-2");

    // Disconnect nvim-2 — should fall back to nvim-1
    c2.end();
    await Bun.sleep(50);
    expect(mgr.getActiveInstance()).toBe("nvim-1");

    c1.end();
    mgr.stop();
  });

  it("responds to ping with pong", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client, receivedData } = await connectClient(TEST_SOCK, "nvim-ping");
    await Bun.sleep(50);

    // Clear handshake_ack
    receivedData.length = 0;

    client.write(encode({ type: "ping" }));
    await Bun.sleep(50);

    expect(receivedData.length).toBeGreaterThanOrEqual(1);
    const pong = decode(receivedData[0]);
    expect(pong.type).toBe("pong");

    client.end();
    mgr.stop();
  });

  it("sendToActive delivers message to active connection", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client, receivedData } = await connectClient(TEST_SOCK, "nvim-send");
    await Bun.sleep(50);
    receivedData.length = 0;

    const sent = mgr.sendToActive({
      id: "m1",
      type: "reply_chunk",
      content: "hello from server",
    });
    expect(sent).toBe(true);

    await Bun.sleep(50);
    expect(receivedData.length).toBeGreaterThanOrEqual(1);
    const msg = decode(receivedData[0]);
    expect(msg.type).toBe("reply_chunk");
    expect((msg as any).content).toBe("hello from server");

    client.end();
    mgr.stop();
  });

  it("sendToActive returns false with no connections", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const sent = mgr.sendToActive({ type: "ping" });
    expect(sent).toBe(false);

    mgr.stop();
  });

  it("broadcast sends to all connected clients", async () => {
    const mgr = new SocketManager(TEST_SOCK);
    await mgr.start(() => {});

    const { client: c1, receivedData: d1 } = await connectClient(TEST_SOCK, "nvim-b1");
    const { client: c2, receivedData: d2 } = await connectClient(TEST_SOCK, "nvim-b2");
    await Bun.sleep(50);
    d1.length = 0;
    d2.length = 0;

    mgr.broadcast({ type: "ping" });
    await Bun.sleep(50);

    expect(d1.length).toBeGreaterThanOrEqual(1);
    expect(d2.length).toBeGreaterThanOrEqual(1);
    expect(decode(d1[0]).type).toBe("ping");
    expect(decode(d2[0]).type).toBe("ping");

    c1.end();
    c2.end();
    mgr.stop();
  });
});

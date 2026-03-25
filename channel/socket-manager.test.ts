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

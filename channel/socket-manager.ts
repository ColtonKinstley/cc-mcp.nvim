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

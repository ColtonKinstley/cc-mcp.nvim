import { describe, it, expect } from "bun:test";
import { encode, decode, LineBuffer, type Message } from "./protocol";

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

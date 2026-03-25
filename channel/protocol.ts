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

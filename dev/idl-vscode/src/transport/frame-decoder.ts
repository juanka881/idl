import { TextDecoder } from "node:util";
import type { JsonRpcMessage } from "./message-transport";

export const maximumHeaderBytes = 8 * 1024;
export const maximumBodyBytes = 16 * 1024 * 1024;

export class FrameDecoder {
  private bufferedBytes = Buffer.alloc(0);
  private readonly utf8Decoder = new TextDecoder("utf-8", {
    fatal: true,
  });

  push(bytes: Buffer): JsonRpcMessage[] {
    this.bufferedBytes = Buffer.concat([this.bufferedBytes, bytes]);
    const messages: JsonRpcMessage[] = [];

    while (true) {
      const headerEnd = this.bufferedBytes.indexOf("\r\n\r\n", "ascii");
      if (headerEnd < 0) {
        this.ensurePartialHeaderFits();
        break;
      }

      const bodyStart = headerEnd + 4;
      if (bodyStart > maximumHeaderBytes) {
        throw new Error("JSON-RPC header exceeds the 8 KiB limit.");
      }

      const bodyLength = this.parseContentLength(this.bufferedBytes.subarray(0, headerEnd));
      const completeFrameLength = bodyStart + bodyLength;
      if (this.bufferedBytes.length < completeFrameLength) {
        break;
      }

      const bodyBytes = this.bufferedBytes.subarray(bodyStart, completeFrameLength);
      const message = this.parseMessage(bodyBytes);
      messages.push(message);
      this.bufferedBytes = this.bufferedBytes.subarray(completeFrameLength);
    }

    return messages;
  }

  finish(): void {
    const hasIncompleteFrame = this.bufferedBytes.length > 0;
    if (hasIncompleteFrame) {
      throw new Error("The language server closed with a truncated JSON-RPC frame.");
    }
  }

  private ensurePartialHeaderFits(): void {
    const headerIsWithinLimit = this.bufferedBytes.length <= maximumHeaderBytes;
    if (!headerIsWithinLimit) {
      throw new Error("JSON-RPC header exceeds the 8 KiB limit.");
    }
  }

  private parseContentLength(headerBytes: Buffer): number {
    const headerText = headerBytes.toString("ascii");
    const headerLines = headerText.split("\r\n");
    let contentLength: number | null = null;

    for (const headerLine of headerLines) {
      const separator = headerLine.indexOf(":");
      const hasSeparator = separator > 0;
      if (!hasSeparator) {
        throw new Error("JSON-RPC header contains a malformed field.");
      }

      const name = headerLine.slice(0, separator).trim().toLowerCase();
      const value = headerLine.slice(separator + 1).trim();
      const isContentLength = name === "content-length";
      if (!isContentLength) {
        continue;
      }

      if (contentLength !== null) {
        throw new Error("JSON-RPC header contains duplicate Content-Length fields.");
      }

      const isDecimalLength = /^(0|[1-9][0-9]*)$/.test(value);
      if (!isDecimalLength) {
        throw new Error("JSON-RPC Content-Length must be a nonnegative decimal integer.");
      }

      const parsedLength = Number(value);
      const isSafeLength = Number.isSafeInteger(parsedLength);
      if (!isSafeLength) {
        throw new Error("JSON-RPC Content-Length is outside the supported range.");
      }

      const bodyIsWithinLimit = parsedLength <= maximumBodyBytes;
      if (!bodyIsWithinLimit) {
        throw new Error("JSON-RPC body exceeds the 16 MiB limit.");
      }

      contentLength = parsedLength;
    }

    if (contentLength === null) {
      throw new Error("JSON-RPC header is missing Content-Length.");
    }

    return contentLength;
  }

  private parseMessage(bodyBytes: Buffer): JsonRpcMessage {
    const bodyText = this.utf8Decoder.decode(bodyBytes);
    const parsed: unknown = JSON.parse(bodyText);
    const isObjectMessage = typeof parsed === "object" && parsed !== null && !Array.isArray(parsed);
    if (!isObjectMessage) {
      throw new Error("JSON-RPC message must be an object.");
    }

    return parsed as JsonRpcMessage;
  }
}

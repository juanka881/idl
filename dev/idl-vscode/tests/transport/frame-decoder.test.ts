import assert from "node:assert/strict";
import test from "node:test";
import {
  FrameDecoder,
  maximumBodyBytes,
  maximumHeaderBytes,
} from "../../src/transport/frame-decoder";

function makeFrame(body: string): Buffer {
  const bodyBytes = Buffer.from(body, "utf8");
  const header = Buffer.from(`Content-Length: ${bodyBytes.byteLength}\r\n\r\n`, "ascii");
  const frame = Buffer.concat([header, bodyBytes]);

  return frame;
}

test("frame decoder handles fragmented and coalesced UTF-8 messages by byte length", () => {
  const decoder = new FrameDecoder();
  const first = makeFrame('{"jsonrpc":"2.0","method":"first","text":"é😀"}');
  const second = makeFrame('{"jsonrpc":"2.0","method":"second"}');
  const coalesced = Buffer.concat([first, second]);
  const firstPart = decoder.push(coalesced.subarray(0, 11));
  const rest = decoder.push(coalesced.subarray(11));

  assert.deepEqual(firstPart, []);
  assert.deepEqual(rest, [
    {
      jsonrpc: "2.0",
      method: "first",
      text: "é😀",
    },
    {
      jsonrpc: "2.0",
      method: "second",
    },
  ]);
  decoder.finish();
});

test("frame decoder rejects duplicate, missing, malformed, and oversized lengths", () => {
  const duplicate = new FrameDecoder();
  const duplicateHeader = Buffer.from(
    "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}",
    "ascii",
  );
  assert.throws(() => duplicate.push(duplicateHeader), /duplicate Content-Length/);

  const malformed = new FrameDecoder();
  assert.throws(() => malformed.push(Buffer.from("Content-Length: -1\r\n\r\n", "ascii")), /nonnegative decimal/);

  const missing = new FrameDecoder();
  assert.throws(() => missing.push(Buffer.from("X-Header: value\r\n\r\n{}", "ascii")), /missing Content-Length/);

  const oversizedBody = new FrameDecoder();
  assert.throws(
    () => oversizedBody.push(Buffer.from(`Content-Length: ${maximumBodyBytes + 1}\r\n\r\n`, "ascii")),
    /16 MiB limit/,
  );

  const oversizedHeader = new FrameDecoder();
  assert.throws(
    () => oversizedHeader.push(Buffer.from("x".repeat(maximumHeaderBytes + 1), "ascii")),
    /8 KiB limit/,
  );
});

test("frame decoder rejects invalid UTF-8, non-object JSON, and truncated frames", () => {
  const invalidUtf8 = new FrameDecoder();
  const badBody = Buffer.from([0xff]);
  const badFrame = Buffer.concat([
    Buffer.from(`Content-Length: ${badBody.byteLength}\r\n\r\n`, "ascii"),
    badBody,
  ]);
  assert.throws(() => invalidUtf8.push(badFrame), /encoded data/);

  const invalidJsonRpc = new FrameDecoder();
  assert.throws(() => invalidJsonRpc.push(makeFrame("[]")), /must be an object/);

  const truncated = new FrameDecoder();
  truncated.push(Buffer.from("Content-Length: 5\r\n\r\n{}", "ascii"));
  assert.throws(() => truncated.finish(), /truncated JSON-RPC frame/);
});

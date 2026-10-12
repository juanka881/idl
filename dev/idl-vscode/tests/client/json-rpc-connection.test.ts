import assert from "node:assert/strict";
import test from "node:test";
import { JsonRpcConnection } from "../../src/client/json-rpc-connection";
import { createMockTransport } from "../helpers/mock-transport";

test("server requests receive method-not-found without dispatching as notifications", async (context) => {
  const transport = createMockTransport(context);
  await transport.start();
  const connection = new JsonRpcConnection(transport.transport);
  let notificationCount = 0;
  connection.onNotification(() => {
    notificationCount += 1;
  });

  const request = connection.request<string>("client/request", {}, 1_000);
  await new Promise<void>((resolve) => setImmediate(resolve));
  const sentMessages = transport.sendMessage.mock.calls.map((call) => call.arguments[0]);
  const outboundRequest = sentMessages.find((message) => message.method === "client/request");
  assert.ok(outboundRequest);
  const requestId = outboundRequest.id;
  assert.ok(typeof requestId === "number");

  transport.deliver({
    jsonrpc: "2.0",
    id: requestId,
    method: "window/showMessage",
    params: {
      type: 1,
      message: "Must not be shown from a request envelope.",
    },
  });
  transport.deliver({
    jsonrpc: "2.0",
    id: requestId,
    method: "window/showMessage",
    result: {},
  });

  assert.equal(notificationCount, 0);
  const responseMessages = transport.sendMessage.mock.calls.map((call) => call.arguments[0]);
  const methodNotFound = responseMessages.find(
    (message) => message.id === requestId && Object.hasOwn(message, "error"),
  );
  assert.deepEqual(methodNotFound?.error, {
    code: -32601,
    message: "Method 'window/showMessage' not found.",
  });

  transport.deliver({
    jsonrpc: "2.0",
    id: requestId,
    result: "completed",
  });
  assert.equal(await request, "completed");

  transport.deliver({
    jsonrpc: "2.0",
    method: "window/showMessage",
    params: {
      type: 1,
      message: "Valid notification.",
    },
  });
  assert.equal(notificationCount, 1);
  connection.dispose();
});

test("malformed matching responses reject their requests", async (context) => {
  const malformedResponses: Array<{
    readonly name: string;
    readonly makeMessage: (id: number) => Record<string, unknown>;
    readonly expectedError: RegExp;
  }> = [
    {
      name: "both result and error",
      makeMessage: (id) => {
        const message = {
          jsonrpc: "2.0",
          id,
          result: "value",
          error: {
            code: -1,
            message: "Failure",
          },
        };

        return message;
      },
      expectedError: /exactly one of result or error/,
    },
    {
      name: "malformed error object",
      makeMessage: (id) => {
        const message = {
          jsonrpc: "2.0",
          id,
          error: {
            code: "bad",
            message: 4,
          },
        };

        return message;
      },
      expectedError: /error requires an integer code and string message/,
    },
    {
      name: "invalid JSON-RPC version",
      makeMessage: (id) => {
        const message = {
          jsonrpc: "1.0",
          id,
          result: "value",
        };

        return message;
      },
      expectedError: /invalid jsonrpc version/,
    },
    {
      name: "non-string method on a matching response ID",
      makeMessage: (id) => {
        const message = {
          jsonrpc: "2.0",
          id,
          method: 123,
          result: "value",
        };

        return message;
      },
      expectedError: /method must be a string/,
    },
  ];

  for (const responseCase of malformedResponses) {
    await context.test(responseCase.name, async () => {
      const transport = createMockTransport(context);
      await transport.start();
      const connection = new JsonRpcConnection(transport.transport);
      const pending = connection.request("pending", {}, 1_000);
      await new Promise<void>((resolve) => setImmediate(resolve));
      const outboundRequest = transport.sendMessage.mock.calls[0]?.arguments[0];
      assert.ok(outboundRequest);
      const requestId = outboundRequest.id;
      assert.ok(typeof requestId === "number");

      transport.deliver(responseCase.makeMessage(requestId));
      await assert.rejects(pending, responseCase.expectedError);
      connection.dispose();
    });
  }
});

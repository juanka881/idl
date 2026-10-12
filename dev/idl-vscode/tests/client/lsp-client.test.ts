import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { LspClient } from "../../src/client/lsp-client";
import { JsonRpcConnection } from "../../src/client/json-rpc-connection";
import { createMockTransport } from "../helpers/mock-transport";
import type { MockMessageTransport } from "../helpers/mock-transport";
import type { JsonRpcMessage } from "../../src/transport/message-transport";

const utf8InitializeResult = {
  capabilities: {
    positionEncoding: "utf-8",
  },
};

function createClient(
  transports: readonly MockMessageTransport[],
  options: {
    readonly maximumWireVersion?: number;
    readonly startupTimeoutMilliseconds?: number;
    readonly requestTimeoutMilliseconds?: number;
    readonly shutdownTimeoutMilliseconds?: number;
    readonly events?: ConstructorParameters<typeof LspClient>[0]["events"];
  } = {},
): LspClient {
  let nextTransportIndex = 0;
  const client = new LspClient({
    transportFactory: () => {
      const mockTransport = transports[nextTransportIndex];
      if (mockTransport === undefined) {
        throw new Error("The test did not provide a transport for this process generation.");
      }

      nextTransportIndex += 1;
      return mockTransport.transport;
    },
    maximumWireVersion: options.maximumWireVersion,
    startupTimeoutMilliseconds: options.startupTimeoutMilliseconds,
    requestTimeoutMilliseconds: options.requestTimeoutMilliseconds,
    shutdownTimeoutMilliseconds: options.shutdownTimeoutMilliseconds,
    events: options.events,
  });

  return client;
}

function installLifecycleResponder(transport: MockMessageTransport): void {
  transport.sendMessage.mock.mockImplementation(async (message) => {
    await respondToLifecycleMessage(transport, message);
  });
}

function createLifecycleTransport(context: TestContext): MockMessageTransport {
  const transport = createMockTransport(context);
  installLifecycleResponder(transport);

  return transport;
}

async function respondToLifecycleMessage(
  transport: MockMessageTransport,
  message: JsonRpcMessage,
): Promise<void> {
  if (message.method === "initialize" && typeof message.id === "number") {
    transport.deliver({
      jsonrpc: "2.0",
      id: message.id,
      result: utf8InitializeResult,
    });
  }

  if (message.method === "shutdown" && typeof message.id === "number") {
    transport.deliver({
      jsonrpc: "2.0",
      id: message.id,
      result: null,
    });
  }

  if (message.method === "exit") {
    transport.close(null, {
      code: 0,
      signal: null,
    });
  }
}

function sentMessages(transport: MockMessageTransport): JsonRpcMessage[] {
  const messages = transport.sendMessage.mock.calls.map((call) => call.arguments[0]);

  return messages;
}

function messagesFor(transport: MockMessageTransport, method: string): JsonRpcMessage[] {
  const messages = sentMessages(transport).filter((message) => message.method === method);

  return messages;
}

function openParams(transport: MockMessageTransport, index = 0): Record<string, unknown> {
  const message = messagesFor(transport, "textDocument/didOpen")[index];
  assert.ok(message);
  return message.params as Record<string, unknown>;
}

function changeParams(transport: MockMessageTransport, index = 0): Record<string, unknown> {
  const message = messagesFor(transport, "textDocument/didChange")[index];
  assert.ok(message);
  return message.params as Record<string, unknown>;
}

test("startup replays only the latest snapshot after initialize and initialized", async (context) => {
  const transport = createMockTransport(context);
  const transports = [transport];
  const client = createClient(transports);
  await client.openDocument("file:///startup.idl", "first");
  const startup = client.start();
  await new Promise<void>((resolve) => setImmediate(resolve));

  await client.changeDocument("file:///startup.idl", {
    text: "latest",
    changes: [],
  });
  const initializeRequest = sentMessages(transport)[0];
  assert.ok(initializeRequest);
  assert.equal(initializeRequest.method, "initialize");
  const initializeRequestId = initializeRequest.id;
  assert.ok(typeof initializeRequestId === "number");
  transport.deliver({
    jsonrpc: "2.0",
    id: initializeRequestId,
    result: utf8InitializeResult,
  });
  await startup;

  const messages = sentMessages(transport);
  const methods = messages.map((message) => message.method);
  assert.deepEqual(methods, [
    "initialize",
    "initialized",
    "textDocument/didOpen",
  ]);
  const initializeMessage = messages[0];
  assert.ok(initializeMessage);
  const initializeParams = initializeMessage.params as Record<string, unknown>;
  const capabilities = initializeParams.capabilities as Record<string, unknown>;
  const textDocument = capabilities.textDocument as Record<string, unknown>;
  const publishDiagnostics = textDocument.publishDiagnostics as Record<string, unknown>;
  assert.equal(publishDiagnostics.versionSupport, true);
  assert.equal((openParams(transport).textDocument as Record<string, unknown>).text, "latest");
});

test("startup deadline stops a transport stuck writing initialized", async (context) => {
  const transport = createMockTransport(context);
  transport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "initialized") {
      return new Promise<void>(() => {});
    }

    await respondToLifecycleMessage(transport, message);
  });
  const transports = [transport];
  const client = createClient(transports, {
    startupTimeoutMilliseconds: 25,
  });

  await assert.rejects(client.start(), /Initializing the Idle language server timed out/);

  assert.equal(client.isRunning, false);
  assert.equal(transport.shutdown.mock.callCount(), 1);
});

test("startup deadline stops a transport stuck replaying didOpen", async (context) => {
  const transport = createMockTransport(context);
  transport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "textDocument/didOpen") {
      return new Promise<void>(() => {});
    }

    await respondToLifecycleMessage(transport, message);
  });
  const transports = [transport];
  const client = createClient(transports, {
    startupTimeoutMilliseconds: 25,
  });
  await client.openDocument("file:///replay-timeout.idl", "snapshot");

  await assert.rejects(client.start(), /Opening Idle documents timed out/);

  assert.equal(client.isRunning, false);
  assert.equal(transport.shutdown.mock.callCount(), 1);
});

test("incremental edits advance versions and gate diagnostics through close and reopen", async (context) => {
  const transports = [createLifecycleTransport(context)];
  const publishedDiagnostics: Array<{ uri: string; diagnostics: unknown }> = [];
  const clearedUris: string[] = [];
  const client = createClient(transports, {
    events: {
      onDiagnostics: (uri, diagnostics) => {
        publishedDiagnostics.push({
          uri,
          diagnostics,
        });
      },
      onClearDiagnostics: (uri) => {
        clearedUris.push(uri);
      },
    },
  });
  await client.start();
  const transport = transports[0];
  assert.ok(transport);
  await client.openDocument("file:///edit.idl", "abc");
  await client.changeDocument("file:///edit.idl", {
    text: "a😀c",
    changes: [
      {
        range: {
          start: {
            line: 0,
            character: 1,
          },
          end: {
            line: 0,
            character: 2,
          },
        },
        text: "😀",
      },
    ],
  });

  const change = changeParams(transport);
  assert.equal((change.textDocument as Record<string, unknown>).version, 2);
  assert.deepEqual(change.contentChanges, [
    {
      range: {
        start: {
          line: 0,
          character: 1,
        },
        end: {
          line: 0,
          character: 2,
        },
      },
      text: "😀",
    },
  ]);

  transport.deliver({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: {
      uri: "file:///edit.idl",
      version: 1,
      diagnostics: [],
    },
  });
  assert.equal(publishedDiagnostics.length, 0);
  transport.deliver({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: {
      uri: "file:///edit.idl",
      version: 2,
      diagnostics: [
        {
          range: {
            start: {
              line: 0,
              character: 1,
            },
            end: {
              line: 0,
              character: 5,
            },
          },
          severity: 1,
          code: "invalid_expression",
          source: "idl",
          message: "Invalid expression syntax.",
          relatedInformation: [
            {
              location: {
                uri: "file:///edit.idl",
                range: {
                  start: {
                    line: 0,
                    character: 0,
                  },
                  end: {
                    line: 0,
                    character: 1,
                  },
                },
              },
              message: "Related location",
            },
          ],
        },
      ],
    },
  });
  assert.equal(publishedDiagnostics.length, 1);
  const convertedDiagnostic = (publishedDiagnostics[0]?.diagnostics as readonly Record<string, unknown>[])[0];
  assert.deepEqual(convertedDiagnostic?.range, {
    start: {
      line: 0,
      character: 1,
    },
    end: {
      line: 0,
      character: 3,
    },
  });
  assert.equal(convertedDiagnostic?.severity, 1);
  assert.equal(convertedDiagnostic?.code, "invalid_expression");
  assert.equal(convertedDiagnostic?.source, "idl");
  assert.deepEqual(convertedDiagnostic?.relatedInformation, [
    {
      uri: "file:///edit.idl",
      range: {
        start: {
          line: 0,
          character: 0,
        },
        end: {
          line: 0,
          character: 1,
        },
      },
      message: "Related location",
    },
  ]);

  await client.closeDocument("file:///edit.idl");
  await client.openDocument("file:///edit.idl", "new");
  const reopened = openParams(transport, 1);
  assert.equal((reopened.textDocument as Record<string, unknown>).version, 3);
  transport.deliver({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: {
      uri: "file:///edit.idl",
      version: 2,
      diagnostics: [],
    },
  });
  assert.equal(publishedDiagnostics.length, 1);
  assert.ok(clearedUris.length >= 3);
  await client.shutdown();
});

test("unpaired surrogates clear diagnostics and recover with a full change", async (context) => {
  const transports = [createLifecycleTransport(context)];
  const errors: string[] = [];
  const clears: string[] = [];
  const client = createClient(transports, {
    events: {
      onErrorMessage: (message) => {
        errors.push(message);
      },
      onClearDiagnostics: (uri) => {
        clears.push(uri);
      },
    },
  });
  await client.start();
  const transport = transports[0];
  assert.ok(transport);
  await client.openDocument("file:///surrogate.idl", "abc");

  await client.changeDocument("file:///surrogate.idl", {
    text: "a\ud800",
    changes: [],
  });
  assert.equal(messagesFor(transport, "textDocument/didChange").length, 0);
  assert.equal(errors.length, 1);
  assert.deepEqual(clears, ["file:///surrogate.idl", "file:///surrogate.idl"]);

  await client.changeDocument("file:///surrogate.idl", {
    text: "recovered",
    changes: [
      {
        range: {
          start: {
            line: 0,
            character: 0,
          },
          end: {
            line: 0,
            character: 1,
          },
        },
        text: "recovered",
      },
    ],
  });
  const fullChange = changeParams(transport);
  assert.deepEqual(fullChange.contentChanges, [
    {
      text: "recovered",
    },
  ]);
  await client.shutdown();
});

test("restart replays current documents and ignores notifications from old generations", async (context) => {
  const transports = [createLifecycleTransport(context), createLifecycleTransport(context)];
  const publishedUris: string[] = [];
  const client = createClient(transports, {
    events: {
      onDiagnostics: (uri) => {
        publishedUris.push(uri);
      },
    },
  });
  await client.start();
  const oldTransport = transports[0];
  assert.ok(oldTransport);
  await client.openDocument("file:///restart.idl", "current");

  await client.restart();
  const newTransport = transports[1];
  assert.ok(newTransport);
  assert.equal((openParams(newTransport).textDocument as Record<string, unknown>).version, 1);
  assert.equal((openParams(newTransport).textDocument as Record<string, unknown>).text, "current");

  oldTransport.deliver({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: {
      uri: "file:///restart.idl",
      version: 1,
      diagnostics: [],
    },
  });
  assert.deepEqual(publishedUris, []);
  await client.shutdown();
});

test("wire version exhaustion starts a fresh process generation", async (context) => {
  const transports = [createLifecycleTransport(context), createLifecycleTransport(context)];
  const client = createClient(transports, {
    maximumWireVersion: 2,
  });
  await client.start();
  await client.openDocument("file:///version.idl", "a");
  await client.changeDocument("file:///version.idl", {
    text: "b",
    changes: [
      {
        range: {
          start: {
            line: 0,
            character: 0,
          },
          end: {
            line: 0,
            character: 1,
          },
        },
        text: "b",
      },
    ],
  });
  await client.changeDocument("file:///version.idl", {
    text: "c",
    changes: [
      {
        range: {
          start: {
            line: 0,
            character: 0,
          },
          end: {
            line: 0,
            character: 1,
          },
        },
        text: "c",
      },
    ],
  });

  const restartedTransport = transports[1];
  assert.ok(restartedTransport);
  assert.equal(restartedTransport.start.mock.callCount(), 1);
  const restartedOpen = openParams(restartedTransport);
  assert.equal((restartedOpen.textDocument as Record<string, unknown>).version, 1);
  assert.equal((restartedOpen.textDocument as Record<string, unknown>).text, "c");
  await client.shutdown();
});

test("request timeouts and process exit reject pending JSON-RPC requests", async (context) => {
  const transports = [createLifecycleTransport(context)];
  const client = createClient(transports, {
    requestTimeoutMilliseconds: 15,
  });
  await client.start();
  const transport = transports[0];
  assert.ok(transport);
  await assert.rejects(client.request("test/neverResponds", {}), /timed out/);

  const connectionTransport = createMockTransport(context);
  await connectionTransport.start();
  const connection = new JsonRpcConnection(connectionTransport.transport);
  const pending = connection.request("test/pending", {}, 5_000);
  await new Promise<void>((resolve) => setImmediate(resolve));
  connectionTransport.close(new Error("process closed"), null);
  await assert.rejects(pending, /process closed/);
  connection.dispose();
  await client.shutdown();
});

test("shutdown sends the lifecycle request before exit and stops the transport", async (context) => {
  const transports = [createLifecycleTransport(context)];
  const client = createClient(transports);
  await client.start();
  const transport = transports[0];
  assert.ok(transport);
  await client.shutdown();

  const methods = sentMessages(transport).map((message) => message.method);
  assert.deepEqual(methods.slice(-2), ["shutdown", "exit"]);
  assert.equal(client.isRunning, false);
});

test("shutdown bounds a stuck request write and a stuck exit notification", async (context) => {
  for (const blockedMethod of ["shutdown", "exit"]) {
    const transport = createMockTransport(context);
    transport.sendMessage.mock.mockImplementation(async (message) => {
      if (message.method === blockedMethod) {
        return new Promise<void>(() => {});
      }

      await respondToLifecycleMessage(transport, message);
    });
    const transports = [transport];
    const client = createClient(transports, {
      shutdownTimeoutMilliseconds: 25,
    });
    await client.start();

    const startedAt = Date.now();
    await client.shutdown();
    const elapsedMilliseconds = Date.now() - startedAt;

    assert.ok(elapsedMilliseconds < 500);
    assert.ok(messagesFor(transport, blockedMethod).length > 0);
    assert.equal(client.isRunning, false);
  }
});

test("an edit during a pending open uses one open and follows it with a change", async (context) => {
  const transport = createLifecycleTransport(context);
  let releaseOpen: (() => void) | undefined;
  transport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "textDocument/didOpen") {
      await new Promise<void>((resolve) => {
        releaseOpen = resolve;
      });
      return;
    }

    await respondToLifecycleMessage(transport, message);
  });
  const transports = [transport];
  const client = createClient(transports);
  await client.start();

  const opening = client.openDocument("file:///pending-open.idl", "first");
  await client.changeDocument("file:///pending-open.idl", {
    text: "latest",
    changes: [
      {
        range: {
          start: {
            line: 0,
            character: 0,
          },
          end: {
            line: 0,
            character: 5,
          },
        },
        text: "latest",
      },
    ],
  });
  assert.ok(releaseOpen);
  releaseOpen();
  await opening;

  assert.equal(messagesFor(transport, "textDocument/didOpen").length, 1);
  assert.equal(messagesFor(transport, "textDocument/didChange").length, 1);
  await client.shutdown();
});

test("close and reopen of one URI keep the new document record", async (context) => {
  const transport = createLifecycleTransport(context);
  let releaseClose: (() => void) | undefined;
  transport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "textDocument/didClose") {
      await new Promise<void>((resolve) => {
        releaseClose = resolve;
      });
      return;
    }

    await respondToLifecycleMessage(transport, message);
  });
  const transports = [transport];
  const client = createClient(transports);
  await client.start();
  await client.openDocument("file:///reopen-race.idl", "old");

  const closing = client.closeDocument("file:///reopen-race.idl");
  await client.openDocument("file:///reopen-race.idl", "new");
  assert.ok(releaseClose);
  releaseClose();
  await closing;
  await client.changeDocument("file:///reopen-race.idl", {
    text: "newer",
    changes: [],
  });

  assert.equal(messagesFor(transport, "textDocument/didOpen").length, 2);
  assert.equal(messagesFor(transport, "textDocument/didChange").length, 1);
  assert.equal((openParams(transport, 1).textDocument as Record<string, unknown>).text, "new");
  await client.shutdown();
});

test("restart during startup starts a new process generation", async (context) => {
  const firstTransport = createMockTransport(context);
  const secondTransport = createLifecycleTransport(context);
  const transports = [firstTransport, secondTransport];
  const client = createClient(transports, {
    startupTimeoutMilliseconds: 500,
  });

  const startup = client.start();
  const startupRejection = assert.rejects(startup, /connection has stopped/);
  await new Promise<void>((resolve) => setImmediate(resolve));
  await client.restart();
  await startupRejection;

  const restartedTransport = transports[1];
  assert.ok(restartedTransport);
  assert.equal(restartedTransport.start.mock.callCount(), 1);
  assert.equal(client.isRunning, true);
  await client.shutdown();
});

test("transport factory errors become actionable server messages", async () => {
  const errors: string[] = [];
  const client = new LspClient({
    transportFactory: () => {
      throw new Error("Set idle.serverPath to an absolute executable path.");
    },
    events: {
      onErrorMessage: (message) => {
        errors.push(message);
      },
    },
  });

  await assert.rejects(client.start(), /absolute executable path/);
  assert.equal(client.isRunning, false);
  assert.match(errors[0] ?? "", /idle.serverPath/);
});

test("shutdown supersedes a restart and waits for its old process stop", async (context) => {
  const transport = createMockTransport(context);
  transport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "shutdown") {
      return new Promise<void>(() => {});
    }

    await respondToLifecycleMessage(transport, message);
  });
  const transports = [transport];
  const client = createClient(transports, {
    shutdownTimeoutMilliseconds: 30,
  });
  await client.start();

  const restarting = client.restart();
  const restartRejection = assert.rejects(restarting, /superseded/);
  await new Promise<void>((resolve) => setImmediate(resolve));
  await client.shutdown();
  await restartRejection;

  assert.equal(transport.shutdown.mock.callCount(), 1);
  assert.equal(client.isRunning, false);
});

test("failed didOpen stops the generation and restart reopens the current snapshot", async (context) => {
  const firstTransport = createMockTransport(context);
  firstTransport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "textDocument/didOpen") {
      throw new Error("The mock rejected didOpen.");
    }

    await respondToLifecycleMessage(firstTransport, message);
  });
  const secondTransport = createLifecycleTransport(context);
  const transports = [firstTransport, secondTransport];
  const errors: string[] = [];
  const client = createClient(transports, {
    events: {
      onErrorMessage: (message) => {
        errors.push(message);
      },
    },
  });
  await client.start();
  await assert.rejects(
    client.openDocument("file:///failed-open.idl", "current open text"),
    /mock rejected didOpen/,
  );

  assert.equal(client.isRunning, false);
  assert.equal(errors.length, 1);
  await client.restart();

  const reopenedParams = openParams(transports[1]!);
  assert.equal((reopenedParams.textDocument as Record<string, unknown>).text, "current open text");
});

test("failed didChange stops the generation and restart sends a full current snapshot", async (context) => {
  const firstTransport = createMockTransport(context);
  firstTransport.sendMessage.mock.mockImplementation(async (message) => {
    if (message.method === "textDocument/didChange") {
      throw new Error("The mock rejected didChange.");
    }

    await respondToLifecycleMessage(firstTransport, message);
  });
  const secondTransport = createLifecycleTransport(context);
  const transports = [firstTransport, secondTransport];
  const client = createClient(transports);
  await client.start();
  await client.openDocument("file:///failed-change.idl", "before");
  await assert.rejects(
    client.changeDocument("file:///failed-change.idl", {
      text: "after edit",
      changes: [
        {
          range: {
            start: {
              line: 0,
              character: 0,
            },
            end: {
              line: 0,
              character: 6,
            },
          },
          text: "after edit",
        },
      ],
    }),
    /mock rejected didChange/,
  );

  assert.equal(client.isRunning, false);
  await client.restart();

  const replayParams = openParams(transports[1]!);
  assert.equal((replayParams.textDocument as Record<string, unknown>).text, "after edit");
});

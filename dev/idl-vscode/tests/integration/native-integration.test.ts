import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import test from "node:test";
import { JsonRpcConnection } from "../../src/client/json-rpc-connection";
import { LspClient, type ClientDiagnostic } from "../../src/client/lsp-client";
import { StdioMessageTransport } from "../../src/transport/stdio-transport";
import type { TransportExit } from "../../src/transport/message-transport";

interface DiagnosticWaiter {
  readonly uri: string;
  readonly matches: (diagnostics: readonly ClientDiagnostic[]) => boolean;
  readonly resolve: (diagnostics: readonly ClientDiagnostic[]) => void;
  readonly reject: (error: Error) => void;
  readonly timer: NodeJS.Timeout;
}

class DiagnosticRecorder {
  private readonly waiters = new Set<DiagnosticWaiter>();

  record(uri: string, diagnostics: readonly ClientDiagnostic[]): void {
    for (const waiter of this.waiters) {
      const uriMatches = waiter.uri === uri;
      const diagnosticsMatch = waiter.matches(diagnostics);
      if (!uriMatches || !diagnosticsMatch) {
        continue;
      }

      clearTimeout(waiter.timer);
      this.waiters.delete(waiter);
      waiter.resolve(diagnostics);
    }
  }

  waitFor(
    uri: string,
    matches: (diagnostics: readonly ClientDiagnostic[]) => boolean,
    timeoutMilliseconds = 8000,
  ): Promise<readonly ClientDiagnostic[]> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(new Error(`Timed out waiting for diagnostics for ${uri}.`));
      }, timeoutMilliseconds);
      const waiter: DiagnosticWaiter = {
        uri,
        matches,
        resolve,
        reject,
        timer,
      };
      this.waiters.add(waiter);
    });
  }
}

function getServerPath(): string {
  let serverPath = process.env.IDLE_SERVER_PATH;
  if (serverPath === undefined || serverPath.length === 0) {
    let executableName = "idl-lsp";
    if (process.platform === "win32") {
      executableName = "idl-lsp.exe";
    }

    serverPath = resolve(__dirname, "../../../../idl-lsp/zig-out/bin", executableName);
  }

  if (!isAbsolute(serverPath)) {
    throw new Error("IDLE_SERVER_PATH must be an absolute path to idl-lsp.");
  }
  if (!existsSync(serverPath)) {
    throw new Error(
      `The native Idle server was not found at ${serverPath}. Build dev/idl-lsp or set IDLE_SERVER_PATH.`,
    );
  }

  return serverPath;
}

function createTransport(serverPath: string): StdioMessageTransport {
  const transport = new StdioMessageTransport(serverPath);
  return transport;
}

async function runInitializationCase(
  serverPath: string,
  positionEncodings: readonly string[] | undefined,
  shouldInitialize: boolean,
): Promise<void> {
  const transport = createTransport(serverPath);
  const connection = new JsonRpcConnection(transport);
  const exitEvents: Array<TransportExit | null> = [];
  const closeSubscription = connection.onClose((event) => {
    exitEvents.push(event.exit);
  });

  await transport.start();
  try {
    const generalCapabilities: Record<string, unknown> = {};
    if (positionEncodings !== undefined) {
      generalCapabilities.positionEncodings = positionEncodings;
    }
    const params = {
      capabilities: {
        general: generalCapabilities,
      },
    };

    if (shouldInitialize) {
      const result = await connection.request<Record<string, unknown>>(
        "initialize",
        params,
        5000,
      );
      const capabilities = result.capabilities as Record<string, unknown>;
      assert.equal(capabilities.positionEncoding, "utf-8");
      await connection.notify("initialized", {});
      await assert.rejects(
        connection.request("idle/unsupported", {}, 5000),
        /not found/i,
      );
      await connection.request("shutdown", null, 5000);
      await connection.notify("exit", null);
      await transport.shutdown(1000);
      const actualExit = exitEvents[0];
      assert.equal(actualExit?.code, 0);
      return;
    }

    await assert.rejects(
      connection.request("initialize", params, 5000),
      /UTF-8/i,
    );
    await connection.notify("exit", null);
    await transport.shutdown(1000);
    const actualExit = exitEvents[0];
    assert.equal(actualExit?.code, 1);
  } finally {
    closeSubscription.dispose();
    connection.dispose();
    await transport.shutdown(100);
  }
}

function noDiagnostics(diagnostics: readonly ClientDiagnostic[]): boolean {
  return diagnostics.length === 0;
}

function hasExpectedValueDiagnostic(diagnostics: readonly ClientDiagnostic[]): boolean {
  const hasExpectedValue = diagnostics.some(
    (diagnostic) => diagnostic.code === "expected_value",
  );
  const hasOnlyExpectedValue = diagnostics.length === 1 && hasExpectedValue;

  return hasOnlyExpectedValue;
}

test("native server handles initialize negotiation and unsupported requests", async () => {
  const serverPath = getServerPath();

  await runInitializationCase(serverPath, ["utf-8"], true);
  await runInitializationCase(serverPath, ["utf-16", "utf-8"], true);
  await runInitializationCase(serverPath, ["utf-16"], false);
  await runInitializationCase(serverPath, ["utf-32"], false);
  await runInitializationCase(serverPath, [], false);
  await runInitializationCase(serverPath, undefined, false);
});

test("native server parses, repairs, reopens, and replays current Idle text", async () => {
  const serverPath = getServerPath();
  const fixturePath = resolve(__dirname, "../../../../idl-lib/tests/fixtures/kitchen-sink.idl");
  const fixture = readFileSync(fixturePath, "utf8");
  let validText = fixture;
  if (!validText.endsWith("\n") && !validText.endsWith("\r")) {
    validText = `${validText}\n`;
  }

  const errorLine = "node 'é😀' key=";
  const errorText = `${validText}${errorLine}`;
  const errorLineIndex = validText.split(/\r\n|\r|\n/).length - 1;
  const uri = "file:///native-integration.idl";
  const diagnostics = new DiagnosticRecorder();
  const client = new LspClient({
    transportFactory: () => createTransport(serverPath),
    events: {
      onDiagnostics: (diagnosticUri, values) => {
        diagnostics.record(diagnosticUri, values);
      },
    },
  });

  try {
    await client.start();
    const invalidWaiter = diagnostics.waitFor(uri, hasExpectedValueDiagnostic);
    await client.openDocument(uri, errorText);
    const invalidDiagnostics = await invalidWaiter;
    assert.equal(invalidDiagnostics[0]?.source, "idl");
    assert.deepEqual(invalidDiagnostics[0]?.range, {
      start: {
        line: errorLineIndex,
        character: errorLine.length,
      },
      end: {
        line: errorLineIndex,
        character: errorLine.length,
      },
    });

    const repairedText = `${errorText}true`;
    const repairedWaiter = diagnostics.waitFor(uri, noDiagnostics);
    await client.changeDocument(uri, {
      text: repairedText,
      changes: [
        {
          range: {
            start: {
              line: errorLineIndex,
              character: errorLine.length,
            },
            end: {
              line: errorLineIndex,
              character: errorLine.length,
            },
          },
          text: "true",
        },
      ],
    });
    await repairedWaiter;

    await client.closeDocument(uri);
    const reopenWaiter = diagnostics.waitFor(uri, noDiagnostics);
    await client.openDocument(uri, validText);
    await reopenWaiter;

    const replayWaiter = diagnostics.waitFor(uri, noDiagnostics);
    await client.restart();
    await replayWaiter;
  } finally {
    await client.shutdown();
  }
});

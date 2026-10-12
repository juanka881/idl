import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test, { type TestContext, type Mock } from "node:test";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { performance } from "node:perf_hooks";
import { StdioMessageTransport } from "../../src/transport/stdio-transport";
import type { TransportExit } from "../../src/transport/message-transport";

interface TestableStdioTransport {
  childProcess: ChildProcessWithoutNullStreams | null;
  attachProcessHandlers(child: ChildProcessWithoutNullStreams): void;
  finishClose(error: Error | null, exit: TransportExit | null): void;
}

type MockChildProcess = EventEmitter & {
  readonly stdin: PassThrough;
  readonly stdout: PassThrough;
  readonly stderr: PassThrough;
  readonly kill: Mock<() => boolean>;
};

interface MockChildProcessFixture {
  readonly child: MockChildProcess;
  readonly kill: Mock<() => boolean>;
}

function createMockChild(context: TestContext): MockChildProcessFixture {
  const emitter = new EventEmitter();
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const kill = context.mock.fn((): boolean => {
    emitter.emit("killed");
    return true;
  });
  const child = Object.assign(emitter, {
    stdin,
    stdout,
    stderr,
    kill,
  }) as MockChildProcess;

  context.after(() => {
    stdin.destroy();
    stdout.destroy();
    stderr.destroy();
  });

  const fixture: MockChildProcessFixture = {
    child,
    kill,
  };

  return fixture;
}

function attachMockChild(transport: StdioMessageTransport, child: MockChildProcess): void {
  const testableTransport = transport as unknown as TestableStdioTransport;
  const processHandle = child as unknown as ChildProcessWithoutNullStreams;
  testableTransport.childProcess = processHandle;
  testableTransport.attachProcessHandlers(processHandle);
}

test("shutdown waits for actual process exit after protocol close, then kills", async (context) => {
  const transport = new StdioMessageTransport("C:\\idle\\idl-lsp.exe");
  const fixture = createMockChild(context);
  const { child } = fixture;
  attachMockChild(transport, child);

  const closeEvents: Array<{ error: Error | null; exit: TransportExit | null }> = [];
  transport.onClose((error, exit) => {
    closeEvents.push({
      error,
      exit,
    });
  });

  const protocolError = new Error("stdin closed unexpectedly");
  const testableTransport = transport as unknown as TestableStdioTransport;
  testableTransport.finishClose(protocolError, null);

  const killObserved = new Promise<void>((resolve) => {
    child.once("killed", resolve);
  });
  const startedAt = performance.now();
  const shutdown = transport.shutdown(30);
  await killObserved;

  const elapsedMilliseconds = performance.now() - startedAt;
  assert.ok(elapsedMilliseconds >= 20);
  assert.equal(closeEvents.length, 1);
  assert.equal(closeEvents[0]?.error, protocolError);
  assert.equal(closeEvents[0]?.exit, null);

  child.emit("close", null, "SIGTERM");
  await shutdown;

  assert.equal(fixture.kill.mock.callCount(), 1);
  assert.equal(closeEvents.length, 1);
});

test("shutdown returns immediately when no child process started", async () => {
  const transport = new StdioMessageTransport("C:\\idle\\idl-lsp.exe");
  const closeEvents: Array<{ error: Error | null; exit: TransportExit | null }> = [];
  transport.onClose((error, exit) => {
    closeEvents.push({
      error,
      exit,
    });
  });

  const startedAt = performance.now();
  await transport.shutdown(1000);
  const elapsedMilliseconds = performance.now() - startedAt;

  assert.ok(elapsedMilliseconds < 100);
  assert.deepEqual(closeEvents, [
    {
      error: null,
      exit: null,
    },
  ]);
});

test("shutdown observes an actual close that arrived before shutdown", async (context) => {
  const transport = new StdioMessageTransport("C:\\idle\\idl-lsp.exe");
  const fixture = createMockChild(context);
  const { child } = fixture;
  attachMockChild(transport, child);
  child.emit("close", 0, null);

  await transport.shutdown(1000);

  assert.equal(fixture.kill.mock.callCount(), 0);
});

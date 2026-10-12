import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { isAbsolute } from "node:path";
import type {
  Disposable,
  JsonRpcMessage,
  MessageTransport,
  TransportExit,
} from "./message-transport";
import { FrameDecoder, maximumBodyBytes } from "./frame-decoder";

export interface StdioTransportOptions {
  readonly onStderr?: (text: string) => void;
}

export class StdioMessageTransport implements MessageTransport {
  private readonly messageListeners = new Set<(message: JsonRpcMessage) => void>();
  private readonly closeListeners = new Set<
    (error: Error | null, exit: TransportExit | null) => void
  >();
  private readonly frameDecoder = new FrameDecoder();
  private readonly processPath: string;
  private readonly options: StdioTransportOptions;
  private childProcess: ChildProcessWithoutNullStreams | null = null;
  private writeQueue: Promise<void> = Promise.resolve();
  private isClosed = false;
  private closeError: Error | null = null;
  private processExit: TransportExit | null = null;
  private processHasExited = false;
  private readonly processExitPromise: Promise<void>;
  private resolveProcessExit: (() => void) | null = null;

  constructor(processPath: string, options: StdioTransportOptions = {}) {
    this.processPath = processPath;
    this.options = options;
    this.processExitPromise = new Promise((resolve) => {
      this.resolveProcessExit = resolve;
    });
  }

  async start(): Promise<void> {
    if (this.childProcess !== null) {
      throw new Error("The language server transport has already started.");
    }

    const processPathIsAbsolute = isAbsolute(this.processPath);
    if (!processPathIsAbsolute) {
      throw new Error("The configured Idle server path must be absolute.");
    }

    const child = spawn(this.processPath, [], {
      shell: false,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.childProcess = child;
    this.attachProcessHandlers(child);

    await new Promise<void>((resolve, reject) => {
      const onSpawn = (): void => {
        child.off("error", onStartupError);
        resolve();
      };
      const onStartupError = (error: Error): void => {
        child.off("spawn", onSpawn);
        reject(error);
      };

      child.once("spawn", onSpawn);
      child.once("error", onStartupError);
    });
  }

  sendMessage(message: JsonRpcMessage): Promise<void> {
    if (this.childProcess === null || this.isClosed) {
      return Promise.reject(new Error("The language server transport is not running."));
    }

    let serializedMessage: string | undefined;
    try {
      serializedMessage = JSON.stringify(message);
    } catch (error) {
      return Promise.reject(toError(error));
    }

    if (serializedMessage === undefined) {
      return Promise.reject(new Error("The JSON-RPC message could not be serialized."));
    }

    const body = Buffer.from(serializedMessage, "utf8");
    const bodyIsWithinLimit = body.byteLength <= maximumBodyBytes;
    if (!bodyIsWithinLimit) {
      return Promise.reject(new Error("JSON-RPC body exceeds the 16 MiB limit."));
    }

    const header = Buffer.from(`Content-Length: ${body.byteLength}\r\n\r\n`, "ascii");
    const frame = Buffer.concat([header, body]);
    const queuedWrite = this.writeQueue.then(() => this.writeFrame(frame));
    this.writeQueue = queuedWrite.catch(() => undefined);

    return queuedWrite;
  }

  onMessage(listener: (message: JsonRpcMessage) => void): Disposable {
    this.messageListeners.add(listener);
    const disposable: Disposable = {
      dispose: () => {
        this.messageListeners.delete(listener);
      },
    };

    return disposable;
  }

  onClose(
    listener: (error: Error | null, exit: TransportExit | null) => void,
  ): Disposable {
    this.closeListeners.add(listener);
    if (this.isClosed) {
      listener(this.closeError, this.processExit);
    }

    const disposable: Disposable = {
      dispose: () => {
        this.closeListeners.delete(listener);
      },
    };

    return disposable;
  }

  async shutdown(killAfterMilliseconds = 3000): Promise<void> {
    const child = this.childProcess;
    if (child === null) {
      this.finishClose(null, null);
      return;
    }

    const gracefulShutdown = this.finishQueuedWritesAndWaitForExit(child);
    const gracefulExit = await waitFor(gracefulShutdown, killAfterMilliseconds);
    if (gracefulExit || this.processHasExited) {
      return;
    }

    child.kill();
    child.stdin.destroy();
    child.stdout.destroy();
    child.stderr.destroy();

    const processClosed = await waitFor(this.processExitPromise, 1000);
    if (!processClosed) {
      child.kill("SIGKILL");
      this.finishClose(new Error("The Idle language server did not stop after termination."), null);
    }
  }

  private attachProcessHandlers(child: ChildProcessWithoutNullStreams): void {
    child.stdout.on("data", (chunk: Buffer) => {
      try {
        const messages = this.frameDecoder.push(chunk);
        for (const message of messages) {
          this.deliverMessage(message);
        }
      } catch (error) {
        this.finishClose(toError(error), null);
        child.kill();
      }
    });

    child.stderr.on("data", (chunk: Buffer) => {
      this.options.onStderr?.(chunk.toString("utf8"));
    });

    child.stdin.on("error", (error: Error) => {
      this.finishClose(error, null);
    });

    child.on("error", (error: Error) => {
      this.finishClose(error, null);
    });

    child.on("close", (code, signal) => {
      let closeError: Error | null = null;
      try {
        this.frameDecoder.finish();
      } catch (error) {
        closeError = toError(error);
      }

      const exit: TransportExit = {
        code,
        signal,
      };
      this.finishProcessExit(exit);
      this.finishClose(closeError, exit);
    });
  }

  private async writeFrame(frame: Buffer): Promise<void> {
    const child = this.childProcess;
    if (child === null || this.isClosed) {
      throw new Error("The language server transport is not running.");
    }

    await new Promise<void>((resolve, reject) => {
      child.stdin.write(frame, (error?: Error | null) => {
        if (error !== undefined && error !== null) {
          reject(error);
          return;
        }

        resolve();
      });
    });
  }

  private async finishQueuedWritesAndWaitForExit(
    child: ChildProcessWithoutNullStreams,
  ): Promise<void> {
    await this.writeQueue;
    if (this.processHasExited) {
      return;
    }

    child.stdin.end();
    await this.processExitPromise;
  }

  private deliverMessage(message: JsonRpcMessage): void {
    for (const listener of this.messageListeners) {
      listener(message);
    }
  }

  private finishClose(error: Error | null, exit: TransportExit | null): void {
    if (this.isClosed) {
      return;
    }

    this.isClosed = true;
    this.closeError = error;
    if (exit !== null) {
      this.processExit = exit;
    }

    for (const listener of this.closeListeners) {
      listener(error, exit);
    }

    this.messageListeners.clear();
    this.closeListeners.clear();
  }

  private finishProcessExit(exit: TransportExit): void {
    if (this.processHasExited) {
      return;
    }

    this.processHasExited = true;
    this.processExit = exit;
    this.resolveProcessExit?.();
    this.resolveProcessExit = null;
  }
}

async function waitFor(promise: Promise<void>, timeoutMilliseconds: number): Promise<boolean> {
  let timeout: NodeJS.Timeout | undefined;
  const timeoutPromise = new Promise<boolean>((resolve) => {
    timeout = setTimeout(() => {
      resolve(false);
    }, timeoutMilliseconds);
  });
  const exitPromise = promise.then(() => true);
  const completed = await Promise.race([exitPromise, timeoutPromise]);
  if (timeout !== undefined) {
    clearTimeout(timeout);
  }

  return completed;
}

function toError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  }

  return new Error(String(value));
}

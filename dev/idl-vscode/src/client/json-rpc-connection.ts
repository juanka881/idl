import type {
  Disposable,
  JsonRpcMessage,
  MessageTransport,
  TransportExit,
} from "../transport/message-transport";

export interface JsonRpcCloseEvent {
  readonly error: Error | null;
  readonly exit: TransportExit | null;
}

interface PendingRequest {
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: Error) => void;
  readonly timer: NodeJS.Timeout;
}

interface JsonRpcErrorObject {
  readonly code: number;
  readonly message: string;
}

export class JsonRpcConnection {
  private readonly transport: MessageTransport;
  private readonly notificationListeners = new Set<(message: JsonRpcMessage) => void>();
  private readonly closeListeners = new Set<(event: JsonRpcCloseEvent) => void>();
  private readonly pendingRequests = new Map<number, PendingRequest>();
  private readonly transportSubscriptions: Disposable[];
  private nextRequestId = 1;
  private isDisposed = false;

  constructor(transport: MessageTransport) {
    this.transport = transport;
    this.transportSubscriptions = [
      transport.onMessage((message) => {
        this.handleMessage(message);
      }),
      transport.onClose((error, exit) => {
        this.handleTransportClose(error, exit);
      }),
    ];
  }

  onNotification(listener: (message: JsonRpcMessage) => void): Disposable {
    this.notificationListeners.add(listener);
    const disposable: Disposable = {
      dispose: () => {
        this.notificationListeners.delete(listener);
      },
    };

    return disposable;
  }

  onClose(listener: (event: JsonRpcCloseEvent) => void): Disposable {
    this.closeListeners.add(listener);
    const disposable: Disposable = {
      dispose: () => {
        this.closeListeners.delete(listener);
      },
    };

    return disposable;
  }

  async request<T>(
    method: string,
    params: unknown,
    timeoutMilliseconds: number,
  ): Promise<T> {
    this.ensureConnectionIsActive();
    const requestId = this.nextRequestId;
    this.nextRequestId += 1;

    const requestMessage: JsonRpcMessage = {
      jsonrpc: "2.0",
      id: requestId,
      method,
      params,
    };

    const result = await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingRequests.delete(requestId);
        reject(new Error(`JSON-RPC request '${method}' timed out.`));
      }, timeoutMilliseconds);
      const pending: PendingRequest = {
        resolve,
        reject,
        timer,
      };
      this.pendingRequests.set(requestId, pending);

      this.transport.sendMessage(requestMessage).catch((error: unknown) => {
        this.rejectPendingRequest(requestId, toError(error));
      });
    });

    return result as T;
  }

  async notify(method: string, params?: unknown): Promise<void> {
    this.ensureConnectionIsActive();
    const message: Record<string, unknown> = {
      jsonrpc: "2.0",
      method,
    };
    if (params !== undefined) {
      message.params = params;
    }

    await this.transport.sendMessage(message);
  }

  dispose(error = new Error("The JSON-RPC connection has stopped.")): void {
    if (this.isDisposed) {
      return;
    }

    this.isDisposed = true;
    for (const subscription of this.transportSubscriptions) {
      subscription.dispose();
    }
    for (const [requestId] of this.pendingRequests) {
      this.rejectPendingRequest(requestId, error);
    }
    this.notificationListeners.clear();
    this.closeListeners.clear();
  }

  private ensureConnectionIsActive(): void {
    if (this.isDisposed) {
      throw new Error("The JSON-RPC connection is closed.");
    }
  }

  private handleMessage(message: JsonRpcMessage): void {
    const isJsonRpcMessage = message.jsonrpc === "2.0";
    if (!isJsonRpcMessage) {
      this.rejectMalformedMatchingResponse(message, "invalid jsonrpc version");
      return;
    }

    const hasMethod = Object.hasOwn(message, "method");
    const hasId = Object.hasOwn(message, "id");
    if (hasMethod) {
      if (typeof message.method !== "string") {
        this.rejectMalformedMatchingResponse(message, "method must be a string");
        return;
      }

      if (hasId) {
        this.handleServerRequest(message);
        return;
      }

      const hasResponseFields =
        Object.hasOwn(message, "result") || Object.hasOwn(message, "error");
      if (hasResponseFields) {
        return;
      }

      for (const listener of this.notificationListeners) {
        listener(message);
      }
      return;
    }

    if (!hasId) {
      return;
    }

    const requestId = message.id;
    const hasNumericRequestId =
      typeof requestId === "number" && Number.isSafeInteger(requestId);
    if (!hasNumericRequestId) {
      return;
    }

    const pending = this.pendingRequests.get(requestId);
    if (pending === undefined) {
      return;
    }

    const hasResult = Object.hasOwn(message, "result");
    const hasError = Object.hasOwn(message, "error");
    const hasExactlyOnePayload = hasResult !== hasError;
    if (!hasExactlyOnePayload) {
      this.rejectPendingRequest(
        requestId,
        new Error("Malformed JSON-RPC response: expected exactly one of result or error."),
      );
      return;
    }

    if (hasError) {
      const errorValue = message.error;
      if (!isValidRpcError(errorValue)) {
        this.rejectPendingRequest(
          requestId,
          new Error("Malformed JSON-RPC response: error requires an integer code and string message."),
        );
        return;
      }

      this.rejectPendingRequest(requestId, new Error(errorValue.message));
      return;
    }

    this.resolvePendingRequest(requestId, message.result);
  }

  private handleServerRequest(message: JsonRpcMessage): void {
    const hasValidRequestId = isValidRequestId(message.id);
    const hasResponseFields =
      Object.hasOwn(message, "result") || Object.hasOwn(message, "error");
    if (!hasValidRequestId || hasResponseFields) {
      return;
    }

    const response: JsonRpcMessage = {
      jsonrpc: "2.0",
      id: message.id,
      error: {
        code: -32601,
        message: `Method '${String(message.method)}' not found.`,
      },
    };
    void this.transport.sendMessage(response).catch(() => undefined);
  }

  private rejectMalformedMatchingResponse(message: JsonRpcMessage, reason: string): void {
    const hasMethod = Object.hasOwn(message, "method");
    const methodIsString = typeof message.method === "string";
    const isValidMethodEnvelope = hasMethod && methodIsString;
    if (isValidMethodEnvelope || !Object.hasOwn(message, "id")) {
      return;
    }

    const requestId = message.id;
    const hasNumericRequestId =
      typeof requestId === "number" && Number.isSafeInteger(requestId);
    if (!hasNumericRequestId || !this.pendingRequests.has(requestId)) {
      return;
    }

    this.rejectPendingRequest(
      requestId,
      new Error(`Malformed JSON-RPC response: ${reason}.`),
    );
  }

  private handleTransportClose(error: Error | null, exit: TransportExit | null): void {
    this.isDisposed = true;
    const closeError = error ?? new Error(formatExit(exit));
    for (const [requestId] of this.pendingRequests) {
      this.rejectPendingRequest(requestId, closeError);
    }

    for (const listener of this.closeListeners) {
      listener({
        error,
        exit,
      });
    }

    this.notificationListeners.clear();
    this.closeListeners.clear();
  }

  private resolvePendingRequest(requestId: number, value: unknown): void {
    const pending = this.pendingRequests.get(requestId);
    if (pending === undefined) {
      return;
    }

    clearTimeout(pending.timer);
    this.pendingRequests.delete(requestId);
    pending.resolve(value);
  }

  private rejectPendingRequest(requestId: number, error: Error): void {
    const pending = this.pendingRequests.get(requestId);
    if (pending === undefined) {
      return;
    }

    clearTimeout(pending.timer);
    this.pendingRequests.delete(requestId);
    pending.reject(error);
  }
}

function isValidRequestId(value: unknown): value is string | number {
  const isStringId = typeof value === "string";
  const isIntegerId = typeof value === "number" && Number.isSafeInteger(value);
  const isValid = isStringId || isIntegerId;

  return isValid;
}

function isValidRpcError(value: unknown): value is JsonRpcErrorObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }

  const errorValue = value as Record<string, unknown>;
  const codeIsInteger = typeof errorValue.code === "number" && Number.isInteger(errorValue.code);
  const messageIsString = typeof errorValue.message === "string";
  const isValid = codeIsInteger && messageIsString;

  return isValid;
}

function formatExit(exit: TransportExit | null): string {
  if (exit === null) {
    return "The language server transport closed.";
  }

  return `The language server exited with code ${String(exit.code)}.`;
}

function toError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  }

  return new Error(String(value));
}

/**
 * Process transport contract. `start` resolves when message delivery is ready.
 *
 * `sendMessage` resolves only after the transport no longer needs the supplied
 * object; the caller may then release or mutate it. Delivered messages are
 * decoded values that the transport will not mutate, so listeners may retain
 * them. Disposing a subscription prevents future calls to that listener.
 * `shutdown` resolves after delivery has stopped and subscriptions are cleared.
 * Pending RPC requests own the request ID and any retained payload until a
 * response, cancellation, or shutdown finishes them.
 */
export type JsonRpcMessage = Readonly<Record<string, unknown>>;

export interface TransportExit {
  readonly code: number | null;
  readonly signal: NodeJS.Signals | null;
}

export interface MessageTransport {
  start(): Promise<void>;
  sendMessage(message: JsonRpcMessage): Promise<void>;
  onMessage(listener: (message: JsonRpcMessage) => void): Disposable;
  onClose(listener: (error: Error | null, exit: TransportExit | null) => void): Disposable;
  shutdown(killAfterMilliseconds?: number): Promise<void>;
}

/** A handle that stops delivery to its listener when disposed. */
export interface Disposable {
  dispose(): void;
}

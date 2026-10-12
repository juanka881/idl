import type { Mock, TestContext } from "node:test";
import type {
  Disposable,
  JsonRpcMessage,
  MessageTransport,
  TransportExit,
} from "../../src/transport/message-transport";

export interface MockMessageTransport {
  readonly transport: MessageTransport;
  readonly start: Mock<MessageTransport["start"]>;
  readonly sendMessage: Mock<MessageTransport["sendMessage"]>;
  readonly onMessage: Mock<MessageTransport["onMessage"]>;
  readonly onClose: Mock<MessageTransport["onClose"]>;
  readonly shutdown: Mock<MessageTransport["shutdown"]>;
  deliver(message: JsonRpcMessage): void;
  close(error: Error | null, exit: TransportExit | null): void;
}

export function createMockTransport(context: TestContext): MockMessageTransport {
  const messageListeners = new Set<(message: JsonRpcMessage) => void>();
  const closeListeners = new Set<
    (error: Error | null, exit: TransportExit | null) => void
  >();

  const start = context.mock.fn(async (): Promise<void> => {});
  const sendMessage = context.mock.fn(async (_message: JsonRpcMessage): Promise<void> => {});
  const onMessage = context.mock.fn((listener: (message: JsonRpcMessage) => void): Disposable => {
    messageListeners.add(listener);

    const subscription: Disposable = {
      dispose: () => {
        messageListeners.delete(listener);
      },
    };

    return subscription;
  });
  const onClose = context.mock.fn(
    (
      listener: (error: Error | null, exit: TransportExit | null) => void,
    ): Disposable => {
      closeListeners.add(listener);

      const subscription: Disposable = {
        dispose: () => {
          closeListeners.delete(listener);
        },
      };

      return subscription;
    },
  );
  const shutdown = context.mock.fn(async (_killAfterMilliseconds?: number): Promise<void> => {});

  const transport: MessageTransport = {
    start,
    sendMessage,
    onMessage,
    onClose,
    shutdown,
  };

  function deliver(message: JsonRpcMessage): void {
    const deliveredMessage = structuredClone(message);
    for (const listener of messageListeners) {
      listener(deliveredMessage);
    }
  }

  function close(error: Error | null, exit: TransportExit | null): void {
    for (const listener of closeListeners) {
      listener(error, exit);
    }
  }

  const mockTransport: MockMessageTransport = {
    transport,
    start,
    sendMessage,
    onMessage,
    onClose,
    shutdown,
    deliver,
    close,
  };

  return mockTransport;
}

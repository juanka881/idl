import {
  createTextCoordinateMapper,
  isWellFormedUtf16,
  prepareIncrementalChanges,
  type EditorRange,
  type EditorTextChange,
  type TextCoordinateMapper,
  type Utf8Position,
  type Utf8Range,
  type Utf8TextChange,
} from "../editor/coordinates";
import type {
  Disposable,
  JsonRpcMessage,
  MessageTransport,
} from "../transport/message-transport";
import { JsonRpcConnection, type JsonRpcCloseEvent } from "./json-rpc-connection";

export interface ClientDiagnosticRelatedInformation {
  readonly uri: string;
  readonly range: EditorRange;
  readonly message: string;
}

export interface ClientDiagnostic {
  readonly range: EditorRange;
  readonly severity?: number;
  readonly code?: string | number;
  readonly source?: string;
  readonly message: string;
  readonly relatedInformation: readonly ClientDiagnosticRelatedInformation[];
}

export interface ClientEvents {
  readonly onDiagnostics?: (uri: string, diagnostics: readonly ClientDiagnostic[]) => void;
  readonly onClearDiagnostics?: (uri: string) => void;
  readonly onErrorMessage?: (message: string) => void;
  readonly onInformationMessage?: (message: string) => void;
  readonly onLog?: (message: string) => void;
}

export interface LspClientOptions {
  readonly transportFactory: () => MessageTransport;
  readonly events?: ClientEvents;
  readonly startupTimeoutMilliseconds?: number;
  readonly requestTimeoutMilliseconds?: number;
  readonly shutdownTimeoutMilliseconds?: number;
  readonly maximumWireVersion?: number;
}

export interface ClientDocumentChange {
  readonly text: string;
  readonly changes: readonly EditorTextChange[];
}

interface DocumentRecord {
  readonly uri: string;
  text: string;
  coordinateMapper: TextCoordinateMapper | null;
  isOpen: boolean;
  isServerOpen: boolean;
  diagnosticsAreCurrent: boolean;
  needsFullResynchronization: boolean;
  wireVersion: number | null;
}

interface ProcessGeneration {
  readonly transport: MessageTransport;
  readonly connection: JsonRpcConnection;
  readonly notificationSubscription: Disposable;
  readonly closeSubscription: Disposable;
  isReady: boolean;
}

interface FullTextChange {
  readonly text: string;
}

type ClientState = "stopped" | "starting" | "running" | "stopping";

const defaultStartupTimeoutMilliseconds = 10_000;
const defaultRequestTimeoutMilliseconds = 5_000;
const defaultShutdownTimeoutMilliseconds = 3_000;
const defaultMaximumWireVersion = 2_147_483_647;

export class LspClient {
  private readonly options: LspClientOptions;
  private readonly documents = new Map<string, DocumentRecord>();
  private readonly wireVersions = new Map<string, number>();
  private state: ClientState = "stopped";
  private lifecycleEpoch = 0;
  private activeGeneration: ProcessGeneration | null = null;
  private startPromise: Promise<void> | null = null;
  private restartPromise: Promise<void> | null = null;
  private readonly pendingStops = new Set<Promise<void>>();
  private readonly startupTimeoutMilliseconds: number;
  private readonly requestTimeoutMilliseconds: number;
  private readonly shutdownTimeoutMilliseconds: number;
  private readonly maximumWireVersion: number;

  constructor(options: LspClientOptions) {
    this.options = options;
    this.startupTimeoutMilliseconds = options.startupTimeoutMilliseconds ?? defaultStartupTimeoutMilliseconds;
    this.requestTimeoutMilliseconds = options.requestTimeoutMilliseconds ?? defaultRequestTimeoutMilliseconds;
    this.shutdownTimeoutMilliseconds = options.shutdownTimeoutMilliseconds ?? defaultShutdownTimeoutMilliseconds;
    this.maximumWireVersion = options.maximumWireVersion ?? defaultMaximumWireVersion;
  }

  get isRunning(): boolean {
    return this.state === "running";
  }

  async request<T>(method: string, params: unknown): Promise<T> {
    const generation = this.activeGeneration;
    if (this.state !== "running" || generation === null || !generation.isReady) {
      throw new Error("The Idle language server is not ready to receive requests.");
    }

    const result = await generation.connection.request<T>(
      method,
      params,
      this.requestTimeoutMilliseconds,
    );

    return result;
  }

  start(): Promise<void> {
    if (this.state === "running") {
      return Promise.resolve();
    }

    if (this.startPromise !== null) {
      return this.startPromise;
    }

    if (this.restartPromise !== null) {
      return this.restartPromise;
    }

    this.lifecycleEpoch += 1;
    const epoch = this.lifecycleEpoch;
    const generationPromise = this.startGeneration(epoch);
    let wrappedPromise: Promise<void>;
    wrappedPromise = generationPromise.finally(() => {
      if (this.startPromise === wrappedPromise) {
        this.startPromise = null;
      }
    });
    this.startPromise = wrappedPromise;

    return wrappedPromise;
  }

  async openDocument(uri: string, text: string): Promise<void> {
    let document = this.documents.get(uri);
    if (document !== undefined && document.isOpen) {
      await this.changeDocument(uri, {
        text,
        changes: [],
      });
      return;
    }

    const coordinateMapper = this.createCoordinateMapper(text);

    if (document === undefined) {
      document = {
        uri,
        text,
        coordinateMapper,
        isOpen: true,
        isServerOpen: false,
        diagnosticsAreCurrent: false,
        needsFullResynchronization: false,
        wireVersion: null,
      };
      this.documents.set(uri, document);
    } else {
      document.text = text;
      document.coordinateMapper = coordinateMapper;
      document.isOpen = true;
      document.isServerOpen = false;
      document.diagnosticsAreCurrent = false;
      document.needsFullResynchronization = false;
      document.wireVersion = null;
    }

    this.clearDiagnostics(uri);
    if (coordinateMapper === null) {
      document.needsFullResynchronization = true;
      this.reportInvalidUnicode(uri);
      return;
    }

    if (this.state === "running") {
      await this.sendDidOpen(document);
    }
  }

  async changeDocument(uri: string, change: ClientDocumentChange): Promise<void> {
    let document = this.documents.get(uri);
    if (document === undefined || !document.isOpen) {
      await this.openDocument(uri, change.text);
      return;
    }

    const previousText = document.text;
    const previousCoordinateMapper = document.coordinateMapper;
    const coordinateMapper = this.createCoordinateMapper(change.text);
    document.text = change.text;
    document.coordinateMapper = coordinateMapper;
    document.diagnosticsAreCurrent = false;
    this.clearDiagnostics(uri);

    const currentTextIsWellFormed = coordinateMapper !== null;
    if (!currentTextIsWellFormed) {
      document.needsFullResynchronization = true;
      this.reportInvalidUnicode(uri);
      return;
    }

    if (this.state !== "running") {
      return;
    }

    const generation = this.activeGeneration;
    if (generation === null) {
      return;
    }

    if (!document.isServerOpen) {
      await this.sendDidOpen(document, generation);
      return;
    }

    let incrementalChanges: readonly Utf8TextChange[] | null = null;
    if (!document.needsFullResynchronization) {
      try {
        incrementalChanges = prepareIncrementalChanges(
          previousText,
          change.text,
          change.changes,
          previousCoordinateMapper ?? undefined,
        );
      } catch (error) {
        this.options.events?.onLog?.(`Using a full Idle document update: ${toError(error).message}`);
      }
    }

    let sentChanges: readonly (Utf8TextChange | FullTextChange)[] =
      incrementalChanges ?? [];
    if (incrementalChanges === null) {
      const fullChange: FullTextChange = {
        text: change.text,
      };
      sentChanges = [fullChange];
    }
    const wireVersion = this.nextWireVersionOrRestart(document);
    if (wireVersion === null) {
      await this.restartPromise;
      return;
    }

    if (this.activeGeneration !== generation) {
      return;
    }

    document.wireVersion = wireVersion;
    document.diagnosticsAreCurrent = true;
    document.needsFullResynchronization = false;
    const params = {
      textDocument: {
        uri,
        version: wireVersion,
      },
      contentChanges: sentChanges,
    };
    try {
      await generation.connection.notify("textDocument/didChange", params);
    } catch (error) {
      if (this.activeGeneration === generation) {
        await this.failGeneration(generation, toError(error));
      }

      throw error;
    }
  }

  async closeDocument(uri: string): Promise<void> {
    const document = this.documents.get(uri);
    if (document === undefined || !document.isOpen) {
      return;
    }

    document.isOpen = false;
    document.diagnosticsAreCurrent = false;
    this.documents.delete(uri);
    this.clearDiagnostics(uri);

    const generation = this.activeGeneration;
    const shouldSendClose =
      this.state === "running" && generation !== null && document.isServerOpen;
    document.isServerOpen = false;
    document.wireVersion = null;
    if (!shouldSendClose || generation === null) {
      return;
    }

    const params = {
      textDocument: {
        uri,
      },
    };
    try {
      await generation.connection.notify("textDocument/didClose", params);
    } catch (error) {
      if (this.activeGeneration === generation) {
        await this.failGeneration(generation, toError(error));
      }

      throw error;
    }
  }

  restart(): Promise<void> {
    if (this.restartPromise !== null) {
      return this.restartPromise;
    }

    this.lifecycleEpoch += 1;
    const epoch = this.lifecycleEpoch;
    this.startPromise = null;
    const restartOperation = this.restartGeneration(epoch);
    let wrappedPromise: Promise<void>;
    wrappedPromise = restartOperation.finally(() => {
      if (this.restartPromise === wrappedPromise) {
        this.restartPromise = null;
      }
    });
    this.restartPromise = wrappedPromise;

    return wrappedPromise;
  }

  async shutdown(): Promise<void> {
    this.lifecycleEpoch += 1;
    const epoch = this.lifecycleEpoch;
    this.startPromise = null;
    this.restartPromise = null;
    const generation = this.activeGeneration;
    this.activeGeneration = null;
    this.state = "stopping";
    this.clearDocumentServerState();

    if (generation !== null) {
      await this.trackGenerationStop(generation, true);
    }

    await Promise.all([...this.pendingStops]);
    if (this.lifecycleEpoch !== epoch) {
      return;
    }

    this.wireVersions.clear();
    this.state = "stopped";
  }

  private async startGeneration(epoch: number): Promise<void> {
    await Promise.all([...this.pendingStops]);
    this.ensureLifecycleIsCurrent(epoch);
    this.state = "starting";
    this.wireVersions.clear();
    let generation: ProcessGeneration;
    try {
      generation = this.createGeneration();
    } catch (error) {
      this.state = "stopped";
      const normalizedError = toError(error);
      this.options.events?.onErrorMessage?.(`Idle language server stopped: ${normalizedError.message}`);
      throw normalizedError;
    }

    this.activeGeneration = generation;
    const startupStartedAt = Date.now();

    try {
      await withTimeout(
        generation.transport.start(),
        this.startupTimeoutMilliseconds,
        "Starting the Idle language server timed out.",
      );
      this.ensureGenerationIsCurrent(generation, epoch);

      const initializeTimeout = this.remainingStartupTime(startupStartedAt);
      const initializeResult = await generation.connection.request<unknown>(
        "initialize",
        initializeParams,
        initializeTimeout,
      );
      this.ensureGenerationIsCurrent(generation, epoch);
      requireUtf8Capability(initializeResult);

      await withTimeout(
        generation.connection.notify("initialized"),
        this.remainingStartupTime(startupStartedAt),
        "Initializing the Idle language server timed out.",
      );
      this.ensureGenerationIsCurrent(generation, epoch);
      generation.isReady = true;
      this.state = "running";
      await withTimeout(
        this.replayOpenDocuments(generation, startupStartedAt, epoch),
        this.remainingStartupTime(startupStartedAt),
        "Replaying Idle documents timed out during startup.",
      );
      this.ensureGenerationIsCurrent(generation, epoch);
    } catch (error) {
      const normalizedError = toError(error);
      if (this.activeGeneration === generation && this.lifecycleEpoch === epoch) {
        await this.failGeneration(generation, normalizedError);
      }

      throw normalizedError;
    }
  }

  private createGeneration(): ProcessGeneration {
    const transport = this.options.transportFactory();
    const connection = new JsonRpcConnection(transport);
    let generation: ProcessGeneration;
    generation = {
      transport,
      connection,
      notificationSubscription: connection.onNotification((message) => {
        this.handleServerNotification(generation, message);
      }),
      closeSubscription: connection.onClose((event) => {
        void this.handleUnexpectedClose(generation, event);
      }),
      isReady: false,
    } satisfies ProcessGeneration;

    return generation;
  }

  private async replayOpenDocuments(
    generation: ProcessGeneration,
    startupStartedAt: number,
    epoch: number,
  ): Promise<void> {
    for (const document of this.documents.values()) {
      this.ensureGenerationIsCurrent(generation, epoch);

      if (!document.isOpen || document.isServerOpen) {
        continue;
      }

      if (document.coordinateMapper === null) {
        document.needsFullResynchronization = true;
        this.reportInvalidUnicode(document.uri);
        continue;
      }

      await withTimeout(
        this.sendDidOpen(document, generation),
        this.remainingStartupTime(startupStartedAt),
        "Opening Idle documents timed out during startup.",
      );
    }
  }

  private async sendDidOpen(
    document: DocumentRecord,
    expectedGeneration = this.activeGeneration,
  ): Promise<void> {
    const generation = expectedGeneration;
    const generationExists = generation !== null;
    if (!generationExists) {
      return;
    }

    const generationIsActive = this.activeGeneration === generation;
    if (!generationIsActive) {
      return;
    }

    const documentIsCurrent = this.documents.get(document.uri) === document;
    if (!documentIsCurrent) {
      return;
    }

    const documentIsOpen = document.isOpen;
    if (!documentIsOpen) {
      return;
    }

    const documentIsAlreadyServerOpen = document.isServerOpen;
    if (documentIsAlreadyServerOpen) {
      return;
    }

    const documentHasCoordinateMapper = document.coordinateMapper !== null;
    if (!documentHasCoordinateMapper) {
      return;
    }

    const textSnapshot = document.text;
    document.isServerOpen = true;
    const wireVersion = this.nextWireVersionOrRestart(document);
    if (wireVersion === null) {
      await this.restartPromise;
      return;
    }

    if (
      this.activeGeneration !== generation ||
      this.documents.get(document.uri) !== document ||
      !document.isOpen
    ) {
      return;
    }

    document.wireVersion = wireVersion;
    document.isServerOpen = true;
    document.diagnosticsAreCurrent = true;
    document.needsFullResynchronization = false;
    const params = {
      textDocument: {
        uri: document.uri,
        languageId: "idle",
        version: wireVersion,
        text: textSnapshot,
      },
    };
    try {
      await generation.connection.notify("textDocument/didOpen", params);
    } catch (error) {
      if (this.activeGeneration === generation) {
        await this.failGeneration(generation, toError(error));
      }

      throw error;
    }
  }

  private nextWireVersionOrRestart(document: DocumentRecord): number | null {
    const lastVersion = this.wireVersions.get(document.uri) ?? 0;
    const canAdvanceVersion = lastVersion < this.maximumWireVersion;
    if (!canAdvanceVersion) {
      const restartOperation = this.restart();
      void restartOperation.catch((error: unknown) => {
        this.options.events?.onLog?.(`Idle language server restart failed: ${toError(error).message}`);
      });
      return null;
    }

    const nextVersion = lastVersion + 1;
    this.wireVersions.set(document.uri, nextVersion);

    return nextVersion;
  }

  private async restartGeneration(epoch: number): Promise<void> {
    const oldGeneration = this.activeGeneration;
    this.activeGeneration = null;
    this.state = "stopping";
    this.clearDocumentServerState();

    if (oldGeneration !== null) {
      await this.trackGenerationStop(oldGeneration, true);
    }
    await Promise.all([...this.pendingStops]);
    this.ensureLifecycleIsCurrent(epoch);

    this.wireVersions.clear();
    this.state = "stopped";
    await this.startGeneration(epoch);
  }

  private async stopGeneration(generation: ProcessGeneration, requestShutdown: boolean): Promise<void> {
    const deadline = Date.now() + this.shutdownTimeoutMilliseconds;
    if (requestShutdown && generation.isReady) {
      try {
        await withTimeout(
          this.sendShutdownSequence(generation),
          this.shutdownTimeoutMilliseconds,
          "Idle language server shutdown timed out.",
        );
      } catch (error) {
        this.options.events?.onLog?.(`Idle server shutdown did not complete cleanly: ${toError(error).message}`);
      }
    }

    generation.connection.dispose();
    generation.notificationSubscription.dispose();
    generation.closeSubscription.dispose();
    const remainingTime = Math.max(0, deadline - Date.now());
    await generation.transport.shutdown(remainingTime);
  }

  private trackGenerationStop(
    generation: ProcessGeneration,
    requestShutdown: boolean,
  ): Promise<void> {
    let stopOperation: Promise<void>;
    stopOperation = this.stopGeneration(generation, requestShutdown).finally(() => {
      this.pendingStops.delete(stopOperation);
    });
    this.pendingStops.add(stopOperation);

    return stopOperation;
  }

  private clearDocumentServerState(): void {
    for (const document of this.documents.values()) {
      document.isServerOpen = false;
      document.diagnosticsAreCurrent = false;
      document.wireVersion = null;
      this.clearDiagnostics(document.uri);
    }
  }

  private async sendShutdownSequence(generation: ProcessGeneration): Promise<void> {
    await generation.connection.request<unknown>(
      "shutdown",
      null,
      this.shutdownTimeoutMilliseconds,
    );
    await generation.connection.notify("exit");
  }

  private async failGeneration(generation: ProcessGeneration, error: Error): Promise<void> {
    if (this.activeGeneration !== generation) {
      return;
    }

    this.activeGeneration = null;
    this.state = "stopped";
    generation.connection.dispose(error);
    generation.notificationSubscription.dispose();
    generation.closeSubscription.dispose();
    for (const document of this.documents.values()) {
      document.isServerOpen = false;
      document.diagnosticsAreCurrent = false;
      document.wireVersion = null;
      this.clearDiagnostics(document.uri);
    }
    this.wireVersions.clear();

    await this.trackGenerationStop(generation, false);
    this.options.events?.onErrorMessage?.(`Idle language server stopped: ${error.message}`);
  }

  private async handleUnexpectedClose(
    generation: ProcessGeneration,
    event: JsonRpcCloseEvent,
  ): Promise<void> {
    if (this.activeGeneration !== generation || this.state === "stopping") {
      return;
    }

    const exitMessage = event.error?.message ?? formatProcessExit(event.exit);
    await this.failGeneration(generation, new Error(exitMessage));
  }

  private handleServerNotification(generation: ProcessGeneration, message: JsonRpcMessage): void {
    if (this.activeGeneration !== generation) {
      return;
    }

    if (message.method === "textDocument/publishDiagnostics") {
      this.handleDiagnostics(generation, message.params);
      return;
    }

    if (message.method === "window/showMessage") {
      this.handleShowMessage(message.params);
    }
  }

  private handleDiagnostics(generation: ProcessGeneration, value: unknown): void {
    const paramsAreRecord = isRecord(value);
    if (!paramsAreRecord) {
      this.logMalformedNotification("publishDiagnostics has invalid params.");
      return;
    }

    const uri = value.uri;
    const uriIsString = typeof uri === "string";
    if (!uriIsString) {
      this.logMalformedNotification("publishDiagnostics has invalid params.");
      return;
    }

    const document = this.documents.get(uri);
    if (document === undefined || !document.isOpen || !document.isServerOpen) {
      return;
    }

    const hasCurrentVersion =
      Number.isInteger(value.version) &&
      document.wireVersion === value.version &&
      document.diagnosticsAreCurrent;
    if (!hasCurrentVersion) {
      return;
    }

    if (!Array.isArray(value.diagnostics)) {
      this.logMalformedNotification("publishDiagnostics has no diagnostics array.");
      return;
    }

    let diagnostics: ClientDiagnostic[];
    try {
      const coordinateMapper = document.coordinateMapper;
      if (coordinateMapper === null) {
        throw new Error("The document has no valid text coordinate map.");
      }

      diagnostics = value.diagnostics.map((item: unknown) =>
        this.convertDiagnostic(uri, coordinateMapper, item),
      );
    } catch (error) {
      this.logMalformedNotification(toError(error).message);
      return;
    }

    if (this.activeGeneration !== generation) {
      return;
    }
    this.options.events?.onDiagnostics?.(document.uri, diagnostics);
  }

  private convertDiagnostic(
    uri: string,
    coordinateMapper: TextCoordinateMapper,
    value: unknown,
  ): ClientDiagnostic {
    const diagnosticIsRecord = isRecord(value);
    if (!diagnosticIsRecord) {
      throw new Error("A server diagnostic has invalid fields.");
    }

    const rangeValue = value.range;
    const rangeIsRecord = isRecord(rangeValue);
    if (!rangeIsRecord) {
      throw new Error("A server diagnostic has invalid fields.");
    }

    const message = value.message;
    const messageIsString = typeof message === "string";
    if (!messageIsString) {
      throw new Error("A server diagnostic has invalid fields.");
    }

    const range = coordinateMapper.utf8RangeToEditor(parseUtf8Range(rangeValue));
    let severity: number | undefined;
    if (value.severity !== undefined) {
      const severityValue = value.severity;
      const severityIsValid =
        typeof severityValue === "number" &&
        Number.isInteger(severityValue) &&
        severityValue >= 1 &&
        severityValue <= 4;
      if (!severityIsValid) {
        throw new Error("A server diagnostic has an invalid severity.");
      }

      severity = severityValue;
    }

    let code: string | number | undefined;
    if (value.code !== undefined) {
      const codeValue = value.code;
      const codeIsValid =
        typeof codeValue === "string" ||
        (typeof codeValue === "number" && Number.isInteger(codeValue));
      if (!codeIsValid) {
        throw new Error("A server diagnostic has an invalid code.");
      }

      code = codeValue;
    }

    let source: string | undefined;
    if (value.source !== undefined) {
      if (typeof value.source !== "string") {
        throw new Error("A server diagnostic has an invalid source.");
      }

      source = value.source;
    }

    const relatedInformation: ClientDiagnosticRelatedInformation[] = [];
    if (value.relatedInformation !== undefined) {
      if (!Array.isArray(value.relatedInformation)) {
        throw new Error("A server diagnostic has invalid related information.");
      }

      for (const relatedValue of value.relatedInformation) {
        const relatedIsRecord = isRecord(relatedValue);
        if (!relatedIsRecord) {
          throw new Error("A related diagnostic location is malformed.");
        }

        const locationValue = relatedValue.location;
        const locationIsRecord = isRecord(locationValue);
        if (!locationIsRecord) {
          throw new Error("A related diagnostic location is malformed.");
        }

        const location = locationValue;
        const relatedUri = location.uri;
        const relatedMessage = relatedValue.message;
        const relatedUriMatches = relatedUri === uri;
        const relatedMessageIsString = typeof relatedMessage === "string";
        if (!relatedMessageIsString) {
          throw new Error("A related diagnostic location is not for this document.");
        }

        const relatedRangeValue = location.range;
        const relatedRangeIsRecord = isRecord(relatedRangeValue);
        if (!relatedRangeIsRecord || !relatedUriMatches) {
          throw new Error("A related diagnostic location is not for this document.");
        }

        const relatedRange = coordinateMapper.utf8RangeToEditor(parseUtf8Range(relatedRangeValue));
        const related: ClientDiagnosticRelatedInformation = {
          uri,
          range: relatedRange,
          message: relatedMessage,
        };
        relatedInformation.push(related);
      }
    }

    const diagnostic: ClientDiagnostic = {
      range,
      severity,
      code,
      source,
      message,
      relatedInformation,
    };

    return diagnostic;
  }

  private handleShowMessage(value: unknown): void {
    const paramsAreRecord = isRecord(value);
    if (!paramsAreRecord) {
      this.logMalformedNotification("window/showMessage has invalid params.");
      return;
    }

    const messageType = value.type;
    const message = value.message;
    const messageTypeIsNumber = typeof messageType === "number";
    const messageIsString = typeof message === "string";
    const paramsAreValid = messageTypeIsNumber && messageIsString;
    if (!paramsAreValid) {
      this.logMalformedNotification("window/showMessage has invalid params.");
      return;
    }

    if (messageType === 1) {
      this.options.events?.onErrorMessage?.(message);
      return;
    }

    this.options.events?.onInformationMessage?.(message);
  }

  private ensureGenerationIsCurrent(generation: ProcessGeneration, epoch: number): void {
    this.ensureLifecycleIsCurrent(epoch);
    if (this.activeGeneration !== generation) {
      throw new Error("The language server generation was stopped during startup.");
    }
  }

  private ensureLifecycleIsCurrent(epoch: number): void {
    if (this.lifecycleEpoch !== epoch) {
      throw new Error("The language server lifecycle operation was superseded.");
    }
  }

  private remainingStartupTime(startupStartedAt: number): number {
    const elapsedMilliseconds = Date.now() - startupStartedAt;
    const remainingMilliseconds = this.startupTimeoutMilliseconds - elapsedMilliseconds;
    const boundedRemainingMilliseconds = Math.max(1, remainingMilliseconds);

    return boundedRemainingMilliseconds;
  }

  private clearDiagnostics(uri: string): void {
    this.options.events?.onClearDiagnostics?.(uri);
  }

  private createCoordinateMapper(text: string): TextCoordinateMapper | null {
    if (!isWellFormedUtf16(text)) {
      return null;
    }

    const coordinateMapper = createTextCoordinateMapper(text);
    return coordinateMapper;
  }

  private reportInvalidUnicode(uri: string): void {
    this.options.events?.onErrorMessage?.(
      `Idle cannot send '${uri}' while it contains an unpaired UTF-16 surrogate.`,
    );
  }

  private logMalformedNotification(message: string): void {
    this.options.events?.onLog?.(`Ignored malformed Idle server notification: ${message}`);
  }
}

const initializeParams = {
  capabilities: {
    general: {
      positionEncodings: ["utf-8"],
    },
    textDocument: {
      publishDiagnostics: {
        versionSupport: true,
        relatedInformation: true,
      },
    },
  },
};

function parseUtf8Range(value: Record<string, unknown>): Utf8Range {
  const start = parseUtf8Position(value.start);
  const end = parseUtf8Position(value.end);
  const range: Utf8Range = {
    start,
    end,
  };

  return range;
}

function parseUtf8Position(value: unknown): Utf8Position {
  if (!isRecord(value)) {
    throw new Error("A server diagnostic position is malformed.");
  }

  const lineIsValid =
    typeof value.line === "number" &&
    Number.isInteger(value.line) &&
    value.line >= 0 &&
    value.line <= 2_147_483_647;
  const characterIsValid =
    typeof value.character === "number" &&
    Number.isInteger(value.character) &&
    value.character >= 0 &&
    value.character <= 2_147_483_647;
  if (!lineIsValid || !characterIsValid) {
    throw new Error("A server diagnostic position is outside signed LSP bounds.");
  }

  const position = {
    line: value.line as number,
    character: value.character as number,
  };

  return position;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireUtf8Capability(value: unknown): void {
  const resultIsRecord = isRecord(value);
  if (!resultIsRecord) {
    throw new Error("The Idle language server returned an invalid initialize result.");
  }

  const capabilities = value.capabilities;
  const capabilitiesAreRecord = isRecord(capabilities);
  if (!capabilitiesAreRecord) {
    throw new Error("The Idle language server returned an invalid initialize result.");
  }

  const isUtf8 = capabilities.positionEncoding === "utf-8";
  if (!isUtf8) {
    throw new Error("The Idle language server did not confirm UTF-8 positions.");
  }
}

async function withTimeout<T>(promise: Promise<T>, timeoutMilliseconds: number, message: string): Promise<T> {
  let timeout: NodeJS.Timeout | undefined;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      reject(new Error(message));
    }, timeoutMilliseconds);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    if (timeout !== undefined) {
      clearTimeout(timeout);
    }
  }
}

function formatProcessExit(event: JsonRpcCloseEvent["exit"]): string {
  if (event === null) {
    return "The Idle language server exited unexpectedly.";
  }

  return `The Idle language server exited with code ${String(event.code)}.`;
}

function toError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  }

  return new Error(String(value));
}

import * as vscode from "vscode";
import { isAbsolute } from "node:path";
import { LspClient, type ClientDiagnostic } from "../client/lsp-client";
import { StdioMessageTransport } from "../transport/stdio-transport";

export class VscodeAdapter {
  private readonly context: vscode.ExtensionContext;
  private readonly output = vscode.window.createOutputChannel("Idle Language Server");
  private readonly diagnostics = vscode.languages.createDiagnosticCollection("idle");
  private readonly client: LspClient;

  constructor(context: vscode.ExtensionContext) {
    this.context = context;
    this.client = new LspClient({
      transportFactory: () => {
        let serverPath = vscode.workspace.getConfiguration("idle").get<string>("serverPath", "");
        if (serverPath.length === 0) {
          const environmentServerPath = process.env.IDLE_SERVER_PATH;
          if (environmentServerPath !== undefined) {
            serverPath = environmentServerPath;
          }
        }

        if (!isAbsolute(serverPath)) {
          throw new Error(
            "Set idle.serverPath to the absolute path of the idl-lsp executable.",
          );
        }

        return new StdioMessageTransport(serverPath, {
          onStderr: (text) => {
            this.output.append(text);
          },
        });
      },
      events: {
        onDiagnostics: (uri, diagnostics) => {
          this.publishDiagnostics(uri, diagnostics);
        },
        onClearDiagnostics: (uri) => {
          this.clearDiagnostics(uri);
        },
        onErrorMessage: (message) => {
          void this.showError(message);
        },
        onInformationMessage: (message) => {
          void vscode.window.showInformationMessage(message);
        },
        onLog: (message) => {
          this.output.appendLine(message);
        },
      },
    });
  }

  activate(): void {
    this.context.subscriptions.push(this.output, this.diagnostics);
    this.context.subscriptions.push(
      vscode.workspace.onDidOpenTextDocument((document) => {
        if (this.isIdleDocument(document)) {
          void this.openDocument(document);
        }
      }),
      vscode.workspace.onDidChangeTextDocument((event) => {
        if (this.isIdleDocument(event.document)) {
          void this.changeDocument(event);
        }
      }),
      vscode.workspace.onDidCloseTextDocument((document) => {
        void this.closeDocument(document);
      }),
      vscode.commands.registerCommand("idle.restartLanguageServer", () => this.restart()),
    );

    for (const document of vscode.workspace.textDocuments) {
      if (this.isIdleDocument(document)) {
        void this.openDocument(document);
      }
    }

    void this.client.start().catch((error: unknown) => {
      this.output.appendLine(`Idle server startup failed: ${toError(error).message}`);
    });
  }

  async deactivate(): Promise<void> {
    await this.client.shutdown();
    this.diagnostics.dispose();
    this.output.dispose();
  }

  private async openDocument(document: vscode.TextDocument): Promise<void> {
    const uri = document.uri.toString();
    try {
      await this.client.openDocument(uri, document.getText());
    } catch (error) {
      this.output.appendLine(`Could not open ${uri}: ${toError(error).message}`);
    }
  }

  private async changeDocument(event: vscode.TextDocumentChangeEvent): Promise<void> {
    const changes = event.contentChanges.map((change) => {
      let range = null;
      if (change.range !== undefined) {
        range = {
          start: {
            line: change.range.start.line,
            character: change.range.start.character,
          },
          end: {
            line: change.range.end.line,
            character: change.range.end.character,
          },
        };
      }

      const editorChange = {
        range,
        text: change.text,
      };

      return editorChange;
    });
    const uri = event.document.uri.toString();
    try {
      await this.client.changeDocument(uri, {
        text: event.document.getText(),
        changes,
      });
    } catch (error) {
      this.output.appendLine(`Could not update ${uri}: ${toError(error).message}`);
    }
  }

  private async closeDocument(document: vscode.TextDocument): Promise<void> {
    const uri = document.uri.toString();
    try {
      await this.client.closeDocument(uri);
    } catch (error) {
      this.output.appendLine(`Could not close ${uri}: ${toError(error).message}`);
    }
  }

  private async restart(): Promise<void> {
    try {
      await this.client.restart();
    } catch (error) {
      this.output.appendLine(`Idle server restart failed: ${toError(error).message}`);
    }
  }

  private async showError(message: string): Promise<void> {
    const action = await vscode.window.showErrorMessage(message, "Restart Server");
    if (action === "Restart Server") {
      await this.restart();
    }
  }

  private publishDiagnostics(uriText: string, values: readonly ClientDiagnostic[]): void {
    let uri: vscode.Uri;
    try {
      uri = vscode.Uri.parse(uriText);
    } catch {
      this.output.appendLine(`Ignored diagnostics with an invalid URI: ${uriText}`);
      return;
    }

    const diagnostics = values.map((value) => this.toVscodeDiagnostic(value));
    this.diagnostics.set(uri, diagnostics);
  }

  private toVscodeDiagnostic(value: ClientDiagnostic): vscode.Diagnostic {
    const range = new vscode.Range(
      value.range.start.line,
      value.range.start.character,
      value.range.end.line,
      value.range.end.character,
    );
    const diagnostic = new vscode.Diagnostic(
      range,
      value.message,
      toDiagnosticSeverity(value.severity),
    );
    diagnostic.code = value.code;
    diagnostic.source = value.source;
    diagnostic.relatedInformation = value.relatedInformation.map((related) => {
      const relatedUri = vscode.Uri.parse(related.uri);
      const relatedRange = new vscode.Range(
        related.range.start.line,
        related.range.start.character,
        related.range.end.line,
        related.range.end.character,
      );
      const location = new vscode.Location(relatedUri, relatedRange);
      const information = new vscode.DiagnosticRelatedInformation(location, related.message);

      return information;
    });

    return diagnostic;
  }

  private clearDiagnostics(uriText: string): void {
    try {
      this.diagnostics.delete(vscode.Uri.parse(uriText));
    } catch {
      this.output.appendLine(`Could not clear diagnostics for invalid URI: ${uriText}`);
    }
  }

  private isIdleDocument(document: vscode.TextDocument): boolean {
    return document.languageId === "idle";
  }
}

function toDiagnosticSeverity(value: number | undefined): vscode.DiagnosticSeverity {
  if (value === 1) {
    return vscode.DiagnosticSeverity.Error;
  }

  if (value === 2) {
    return vscode.DiagnosticSeverity.Warning;
  }

  if (value === 3) {
    return vscode.DiagnosticSeverity.Information;
  }

  return vscode.DiagnosticSeverity.Hint;
}

function toError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  }

  return new Error(String(value));
}

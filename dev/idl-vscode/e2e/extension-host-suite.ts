import assert from "node:assert/strict";
import {
  commands,
  languages,
  Position,
  Uri,
  window,
  workspace,
} from "vscode";
import type { Diagnostic, Disposable, TextEditor } from "vscode";

type DiagnosticPredicate = (diagnostics: readonly Diagnostic[]) => boolean;

function requiredEnvironmentValue(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`The extension test requires ${name}.`);
  }

  return value;
}

function waitForDiagnostics(
  uri: Uri,
  matches: DiagnosticPredicate,
  label: string,
  timeoutMilliseconds = 10000,
): Promise<readonly Diagnostic[]> {
  return new Promise((resolve, reject) => {
    let subscription: Disposable | null = null;
    const timeout = setTimeout(() => {
      subscription?.dispose();
      const currentDocument = workspace.textDocuments.find(
        (document) => document.uri.toString() === uri.toString(),
      );
      const currentDiagnostics = languages.getDiagnostics(uri);
      const diagnosticDetails = currentDiagnostics.map((diagnostic) => {
        const detail = {
          code: diagnostic.code,
          message: diagnostic.message,
          range: diagnostic.range,
        };

        return detail;
      });
      let currentText = "<closed>";
      if (currentDocument !== undefined) {
        currentText = currentDocument.getText();
      }
      reject(
        new Error(
          `Timed out waiting for ${label} diagnostics for ${uri.toString()}; text: ${JSON.stringify(currentText)}; diagnostics: ${JSON.stringify(diagnosticDetails)}.`,
        ),
      );
    }, timeoutMilliseconds);

    subscription = languages.onDidChangeDiagnostics((event) => {
      const uriChanged = event.uris.some((changedUri) => changedUri.toString() === uri.toString());
      if (!uriChanged) {
        return;
      }

      const diagnostics = languages.getDiagnostics(uri);
      if (!matches(diagnostics)) {
        return;
      }

      clearTimeout(timeout);
      subscription?.dispose();
      resolve(diagnostics);
    });
  });
}

function hasExpectedValue(diagnostics: readonly Diagnostic[]): boolean {
  return diagnostics.some((diagnostic) => diagnostic.code === "expected_value");
}

function hasNoDiagnostics(diagnostics: readonly Diagnostic[]): boolean {
  return diagnostics.length === 0;
}

function waitForClose(uri: Uri): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let subscription: Disposable | null = null;
    const timeout = setTimeout(() => {
      subscription?.dispose();
      reject(new Error(`Timed out waiting for ${uri.toString()} to close.`));
    }, 10000);
    subscription = workspace.onDidCloseTextDocument((document) => {
      const documentClosed = document.uri.toString() === uri.toString();
      if (!documentClosed) {
        return;
      }

      clearTimeout(timeout);
      subscription?.dispose();
      resolve();
    });
  });
}

async function insertAtEnd(editor: TextEditor, text: string): Promise<void> {
  const lastLineIndex = editor.document.lineCount - 1;
  const lastLine = editor.document.lineAt(lastLineIndex);
  const position = new Position(lastLineIndex, lastLine.text.length);
  const editWasApplied = await editor.edit((builder) => {
    builder.insert(position, text);
  });
  assert.ok(editWasApplied);
}

export async function run(): Promise<void> {
  const testFilePath = requiredEnvironmentValue("IDLE_HOST_TEST_FILE");
  const errorLine = requiredEnvironmentValue("IDLE_HOST_TEST_ERROR_LINE");
  const errorLineIndex = Number(requiredEnvironmentValue("IDLE_HOST_TEST_FIXTURE_END_LINE"));
  const uri = Uri.file(testFilePath);
  const initialDiagnosticWaiter = waitForDiagnostics(uri, hasExpectedValue, "initial");
  const document = await workspace.openTextDocument(uri);
  assert.equal(document.languageId, "idle");
  let editor = await window.showTextDocument(document, {
    preview: false,
  });

  const initialDiagnostics = await initialDiagnosticWaiter;
  assert.equal(initialDiagnostics.length, 1);
  const initialDiagnostic = initialDiagnostics[0];
  assert.ok(initialDiagnostic);
  assert.equal(initialDiagnostic.code, "expected_value");
  assert.equal(initialDiagnostic.source, "idl");
  assert.equal(initialDiagnostic.range.start.line, errorLineIndex);
  assert.equal(initialDiagnostic.range.end.line, errorLineIndex);
  assert.equal(initialDiagnostic.range.start.character, errorLine.length);
  assert.equal(initialDiagnostic.range.end.character, errorLine.length);

  const fixWaiter = waitForDiagnostics(uri, hasNoDiagnostics, "fix");
  await insertAtEnd(editor, "true");
  await fixWaiter;

  const undoWaiter = waitForDiagnostics(uri, hasExpectedValue, "undo");
  await commands.executeCommand("undo");
  assert.equal(window.activeTextEditor?.document.uri.toString(), uri.toString());
  assert.ok(editor.document.getText().endsWith(errorLine));
  await undoWaiter;

  const redoWaiter = waitForDiagnostics(uri, hasNoDiagnostics, "redo");
  await commands.executeCommand("redo");
  await redoWaiter;
  const documentWasSaved = await editor.document.save();
  assert.ok(documentWasSaved);

  const errorBeforeCloseWaiter = waitForDiagnostics(uri, hasExpectedValue, "pre-close");
  await insertAtEnd(editor, `\n${errorLine}`);
  await errorBeforeCloseWaiter;
  const savedErrorDocument = await editor.document.save();
  assert.ok(savedErrorDocument);

  const closeDiagnosticWaiter = waitForDiagnostics(uri, hasNoDiagnostics, "close");
  await commands.executeCommand("workbench.action.closeAllEditors");
  const closeWaiter = waitForClose(uri);
  const plainTextDocument = await languages.setTextDocumentLanguage(
    editor.document,
    "plaintext",
  );
  await closeWaiter;
  await closeDiagnosticWaiter;
  assert.equal(plainTextDocument.languageId, "plaintext");

  const reopenDiagnosticWaiter = waitForDiagnostics(uri, hasExpectedValue, "reopen");
  const reopenedDocument = await languages.setTextDocumentLanguage(plainTextDocument, "idle");
  assert.equal(reopenedDocument.languageId, "idle");
  editor = await window.showTextDocument(reopenedDocument, {
    preview: false,
  });
  await reopenDiagnosticWaiter;

  const replayDiagnosticWaiter = waitForDiagnostics(uri, hasExpectedValue, "restart replay");
  await commands.executeCommand("idle.restartLanguageServer");
  await replayDiagnosticWaiter;
}

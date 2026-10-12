import assert from "node:assert/strict";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";
import { runTests } from "@vscode/test-electron";

function requiredAbsolutePath(value: string | undefined, label: string): string {
  if (value === undefined || value.length === 0 || !isAbsolute(value)) {
    throw new Error(`${label} must be set to an absolute path.`);
  }

  return value;
}

function getExecutablePath(): string {
  let executablePath = process.env.VSCODE_EXECUTABLE_PATH;
  if (executablePath === undefined || executablePath.length === 0) {
    executablePath = "C:\\Program Files\\Microsoft VS Code\\Code.exe";
  }

  return requiredAbsolutePath(executablePath, "VSCODE_EXECUTABLE_PATH");
}

function getServerPath(packageRoot: string): string {
  let serverPath = process.env.IDLE_SERVER_PATH;
  if (serverPath === undefined || serverPath.length === 0) {
    let executableName = "idl-lsp";
    if (process.platform === "win32") {
      executableName = "idl-lsp.exe";
    }

    serverPath = resolve(packageRoot, "../idl-lsp/zig-out/bin", executableName);
  }

  return requiredAbsolutePath(serverPath, "IDLE_SERVER_PATH");
}

async function main(): Promise<void> {
  const packageRoot = resolve(__dirname, "../..");
  const repositoryRoot = resolve(packageRoot, "../..");
  const workspaceRoot = resolve(packageRoot, ".test-workspace");
  const dataRoot = resolve(packageRoot, ".test-data");
  const runId = `${process.pid}-${randomUUID()}`;
  const workspacePath = resolve(workspaceRoot, runId);
  const dataPath = resolve(dataRoot, runId);
  const userDataPath = resolve(dataPath, "user-data");
  const extensionsPath = resolve(dataPath, "extensions");
  const settingsPath = resolve(workspacePath, ".vscode", "settings.json");
  const fixturePath = resolve(repositoryRoot, "dev/idl-lib/tests/fixtures/kitchen-sink.idl");
  const testFilePath = resolve(workspacePath, "native-extension-test.idl");
  const serverPath = getServerPath(packageRoot);
  const fixture = readFileSync(fixturePath, "utf8");
  let fixtureWithLineBreak = fixture;
  if (!fixtureWithLineBreak.endsWith("\n") && !fixtureWithLineBreak.endsWith("\r")) {
    fixtureWithLineBreak = `${fixtureWithLineBreak}\n`;
  }

  const errorLine = "node 'é😀' key=";
  const testSource = `${fixtureWithLineBreak}${errorLine}`;
  assert.equal(isStrictChild(workspaceRoot, workspacePath), true);
  assert.equal(isStrictChild(dataRoot, dataPath), true);

  mkdirSync(resolve(workspacePath, ".vscode"), {
    recursive: true,
  });
  mkdirSync(userDataPath, {
    recursive: true,
  });
  mkdirSync(extensionsPath, {
    recursive: true,
  });
  const idleSettings = {
    serverPath,
  };
  const workspaceSettings = {
    idle: idleSettings,
  };
  writeFileSync(settingsPath, `${JSON.stringify(workspaceSettings, null, 2)}\n`, "utf8");
  writeFileSync(testFilePath, testSource, "utf8");

  try {
    const exitCode = await runTests({
      vscodeExecutablePath: getExecutablePath(),
      extensionDevelopmentPath: packageRoot,
      extensionTestsPath: resolve(packageRoot, "out/e2e/extension-host-suite.js"),
      extensionTestsEnv: {
        IDLE_HOST_TEST_FILE: testFilePath,
        IDLE_HOST_TEST_ERROR_LINE: errorLine,
        IDLE_HOST_TEST_FIXTURE_END_LINE: String(
          fixtureWithLineBreak.split(/\r\n|\r|\n/).length - 1,
        ),
      },
      launchArgs: [
        workspacePath,
        `--user-data-dir=${userDataPath}`,
        `--extensions-dir=${extensionsPath}`,
      ],
    });
    assert.equal(exitCode, 0);
  } finally {
    removeOwnedDirectory(dataRoot, dataPath);
    removeOwnedDirectory(workspaceRoot, workspacePath);
  }
}

function isStrictChild(parentPath: string, childPath: string): boolean {
  const relativePath = relative(parentPath, childPath);
  const childIsWithinParent =
    relativePath.length > 0 &&
    relativePath !== ".." &&
    !relativePath.startsWith(`..${sep}`) &&
    !isAbsolute(relativePath);

  return childIsWithinParent;
}

function removeOwnedDirectory(parentPath: string, childPath: string): void {
  if (!isStrictChild(parentPath, childPath)) {
    throw new Error(`Refusing to remove a test directory outside ${parentPath}.`);
  }

  rmSync(childPath, {
    recursive: true,
    force: true,
  });
}

void main().catch((error: unknown) => {
  let errorMessage = String(error);
  if (error instanceof Error) {
    errorMessage = error.stack ?? error.message;
  }

  process.stderr.write(`${errorMessage}\n`);
  process.exitCode = 1;
});

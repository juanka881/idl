import type { ExtensionContext } from "vscode";
import { VscodeAdapter } from "./editor/vscode-adapter";

let adapter: VscodeAdapter | null = null;

export function activate(context: ExtensionContext): void {
  adapter = new VscodeAdapter(context);
  adapter.activate();
}

export async function deactivate(): Promise<void> {
  if (adapter !== null) {
    await adapter.deactivate();
    adapter = null;
  }
}

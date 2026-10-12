import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  INITIAL,
  Registry,
  parseRawGrammar,
  type IGrammar,
  type StateStack,
} from "vscode-textmate";
import { OnigScanner, OnigString, loadWASM } from "vscode-oniguruma";

interface TokenLine {
  readonly text: string;
  readonly tokens: readonly TokenScope[];
}

interface TokenScope {
  readonly startIndex: number;
  readonly scopes: readonly string[];
}

let onigurumaLoad: Promise<void> | null = null;

async function createGrammar(): Promise<IGrammar> {
  const grammarPath = resolve(__dirname, "../../../syntaxes/idle.tm-language.json");
  const grammarSource = readFileSync(grammarPath, "utf8");
  const grammar = parseRawGrammar(grammarSource, grammarPath);
  await loadOniguruma();

  const registry = new Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new OnigScanner(patterns),
      createOnigString: (value) => new OnigString(value),
    }),
    loadGrammar: async (scopeName) => {
      if (scopeName === "source.idle") {
        return grammar;
      }

      return null;
    },
  });
  const loadedGrammar = await registry.loadGrammar("source.idle");
  if (loadedGrammar === null) {
    throw new Error("The Idle grammar could not be loaded.");
  }

  return loadedGrammar;
}

async function loadOniguruma(): Promise<void> {
  if (onigurumaLoad !== null) {
    await onigurumaLoad;
    return;
  }

  const wasmPath = require.resolve("vscode-oniguruma/release/onig.wasm");
  const wasm = readFileSync(wasmPath);
  const wasmBuffer = wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength);
  onigurumaLoad = loadWASM(wasmBuffer);
  await onigurumaLoad;
}

function tokenize(text: string, grammar: IGrammar): TokenLine[] {
  const lines = text.split(/\r\n|\r|\n/);
  const tokenLines: TokenLine[] = [];
  let ruleStack: StateStack = INITIAL;

  for (const line of lines) {
    const result = grammar.tokenizeLine(line, ruleStack);
    const tokenLine: TokenLine = {
      text: line,
      tokens: result.tokens.map((token) => {
        const tokenScope: TokenScope = {
          startIndex: token.startIndex,
          scopes: token.scopes,
        };

        return tokenScope;
      }),
    };
    tokenLines.push(tokenLine);
    ruleStack = result.ruleStack;
  }

  return tokenLines;
}

function hasScopeAt(line: TokenLine, text: string, scope: string): boolean {
  const index = line.text.indexOf(text);
  if (index < 0) {
    return false;
  }

  return hasScopeAtIndex(line, index, scope);
}

function hasScopeAtIndex(line: TokenLine, index: number, scope: string): boolean {
  const indexIsInLine = index >= 0 && index < line.text.length;
  if (!indexIsInLine) {
    return false;
  }

  for (let tokenIndex = 0; tokenIndex < line.tokens.length; tokenIndex += 1) {
    const token = line.tokens[tokenIndex];
    if (token === undefined) {
      continue;
    }

    const nextToken = line.tokens[tokenIndex + 1];
    let tokenEnd = line.text.length;
    if (nextToken !== undefined) {
      tokenEnd = nextToken.startIndex;
    }

    const indexIsInToken = index >= token.startIndex && index < tokenEnd;
    if (indexIsInToken && token.scopes.includes(scope)) {
      return true;
    }
  }

  return false;
}

function hasScopeAcross(line: TokenLine, text: string, scope: string): boolean {
  const index = line.text.indexOf(text);
  if (index < 0) {
    return false;
  }

  for (let offset = 0; offset < text.length; offset += 1) {
    const characterHasScope = hasScopeAtIndex(line, index + offset, scope);
    if (!characterHasScope) {
      return false;
    }
  }

  return true;
}

function lineContaining(lines: readonly TokenLine[], text: string): TokenLine {
  const line = lines.find((candidate) => candidate.text.includes(text));
  if (line === undefined) {
    throw new Error(`Expected to find line containing ${text}.`);
  }

  return line;
}

test("Idle grammar tokenizes the shared kitchen-sink fixture", async () => {
  const grammar = await createGrammar();
  const fixturePath = resolve(__dirname, "../../../../idl-lib/tests/fixtures/kitchen-sink.idl");
  const fixture = readFileSync(fixturePath, "utf8");
  const lines = tokenize(fixture, grammar);

  const commentLine = lineContaining(lines, "// A node can be empty");
  assert.ok(hasScopeAt(commentLine, "//", "comment.line.double-slash.idle"));

  const stringLine = lineContaining(lines, "// and /* are string content */");
  assert.ok(hasScopeAt(stringLine, "// and", "string.quoted.single.idle"));

  const blockCommentLine = lineContaining(lines, "spanning a physical line */ after");
  assert.ok(hasScopeAt(blockCommentLine, "spanning", "comment.block.idle"));

  const multilineStringLine = lineContaining(lines, "      more-indented");
  assert.ok(hasScopeAt(multilineStringLine, "more-indented", "string.quoted.single.marked.literal.idle"));

  const foldedStringLine = lineContaining(lines, "      indented code");
  assert.ok(hasScopeAt(foldedStringLine, "indented code", "string.quoted.single.marked.folded.idle"));

  const annotationLine = lineContaining(lines, "@meta 'kitchen'");
  assert.ok(hasScopeAt(annotationLine, "@meta", "entity.name.tag.annotation.idle"));

  const numberLine = lineContaining(lines, "numeric_header -42");
  assert.ok(hasScopeAt(numberLine, "42", "constant.numeric.idle"));

  const booleanLine = lineContaining(lines, "enabled=true");
  assert.ok(hasScopeAt(booleanLine, "true", "constant.language.boolean.idle"));
});

test("Idle grammar scopes complete numeric tokens and malformed candidates", async () => {
  const grammar = await createGrammar();
  const validValues = [
    "0xFF",
    "0x10",
    "0x10B",
    "0x10ms",
    "3.14",
    "1e-3",
    "1e3",
    "1e3ms",
    "30ms",
    "1em",
    "1e",
  ];
  const validLineText = `valid ${validValues.join(" ")}`;
  const validLine = tokenize(validLineText, grammar)[0];
  assert.notEqual(validLine, undefined);
  for (const value of validValues) {
    assert.ok(hasScopeAcross(validLine, value, "constant.numeric.idle"), value);
  }

  const malformedLineText = "invalid 0x 01 .5 1. 1.2.3 30ms2 0x1p2 42:foo 1$bar 1😀";
  const malformedLine = tokenize(malformedLineText, grammar)[0];
  assert.notEqual(malformedLine, undefined);
  for (const value of [
    "0x",
    "01",
    ".5",
    "1.",
    "1.2.3",
    "30ms2",
    "0x1p2",
    "42:foo",
    "1$bar",
    "1😀",
  ]) {
    assert.ok(hasScopeAcross(malformedLine, value, "invalid.illegal.numeric.idle"), value);
  }

  const malformedExponentLine = tokenize("invalid 1e-3ms2 1.2e+3bad2", grammar)[0];
  assert.notEqual(malformedExponentLine, undefined);
  for (const prefix of ["1e", "1.2e"]) {
    assert.equal(
      hasScopeAcross(malformedExponentLine, prefix, "constant.numeric.idle"),
      false,
      prefix,
    );
  }

  // `$` is not excluded punctuation in spec section 7, so `$42` is one word rather than a number suffix.
  const symbolLine = tokenize("symbol $42", grammar)[0];
  assert.notEqual(symbolLine, undefined);
  assert.equal(hasScopeAcross(symbolLine, "$42", "constant.numeric.idle"), false);
  assert.equal(hasScopeAcross(symbolLine, "$42", "invalid.illegal.numeric.idle"), false);
});

test("Idle grammar keeps quote and comment markers in their lexical contexts", async () => {
  const grammar = await createGrammar();
  const source = [
    "quoted='// /* text' // trailing comment",
    "/* 'quoted' // still block */ value='still a string'",
    "marked=|'first line",
    "second line'",
  ].join("\n");
  const lines = tokenize(source, grammar);

  assert.ok(hasScopeAt(lines[0]!, "// /* text", "string.quoted.single.idle"));
  assert.ok(hasScopeAt(lines[0]!, "trailing comment", "comment.line.double-slash.idle"));
  assert.ok(hasScopeAt(lines[1]!, "'quoted'", "comment.block.idle"));
  assert.ok(hasScopeAt(lines[1]!, "still a string", "string.quoted.single.idle"));
  assert.ok(hasScopeAt(lines[2]!, "first line", "string.quoted.single.marked.literal.idle"));
  assert.ok(hasScopeAt(lines[3]!, "second line", "string.quoted.single.marked.literal.idle"));
});

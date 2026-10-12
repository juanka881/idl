import assert from "node:assert/strict";
import test from "node:test";
import {
  convertEditorRangeToUtf8,
  convertUtf8RangeToEditor,
  createTextCoordinateMapper,
  isWellFormedUtf16,
  prepareIncrementalChanges,
  type EditorTextChange,
} from "../../src/editor/coordinates";

test("UTF-16 editor positions convert to UTF-8 bytes across CRLF and Unicode", () => {
  const text = "é😀x\r\nlast";
  const range = convertEditorRangeToUtf8(text, {
    start: {
      line: 0,
      character: 1,
    },
    end: {
      line: 0,
      character: 3,
    },
  });

  assert.deepEqual(range, {
    start: {
      line: 0,
      character: 2,
    },
    end: {
      line: 0,
      character: 6,
    },
  });

  const editorRange = convertUtf8RangeToEditor(text, range);
  assert.deepEqual(editorRange, {
    start: {
      line: 0,
      character: 1,
    },
    end: {
      line: 0,
      character: 3,
    },
  });
});

test("editor change batches sort descending and reconstruct the new snapshot", () => {
  const before = "alpha\r\né😀omega";
  const after = "ALPHA\r\né😀OMEGA";
  const changes: EditorTextChange[] = [
    {
      range: {
        start: {
          line: 1,
          character: 3,
        },
        end: {
          line: 1,
          character: 8,
        },
      },
      text: "OMEGA",
    },
    {
      range: {
        start: {
          line: 0,
          character: 0,
        },
        end: {
          line: 0,
          character: 5,
        },
      },
      text: "ALPHA",
    },
  ];

  assert.deepEqual(prepareIncrementalChanges(before, after, changes), [
    {
      range: {
        start: {
          line: 1,
          character: 6,
        },
        end: {
          line: 1,
          character: 11,
        },
      },
      text: "OMEGA",
    },
    {
      range: {
        start: {
          line: 0,
          character: 0,
        },
        end: {
          line: 0,
          character: 5,
        },
      },
      text: "ALPHA",
    },
  ]);
});

test("overlapping, tied, and unreconstructable edits request full replacement", () => {
  const before = "abcdef";
  const overlapping: EditorTextChange[] = [
    {
      range: {
        start: {
          line: 0,
          character: 1,
        },
        end: {
          line: 0,
          character: 4,
        },
      },
      text: "X",
    },
    {
      range: {
        start: {
          line: 0,
          character: 3,
        },
        end: {
          line: 0,
          character: 5,
        },
      },
      text: "Y",
    },
  ];
  const tied: EditorTextChange[] = [
    {
      range: {
        start: {
          line: 0,
          character: 2,
        },
        end: {
          line: 0,
          character: 2,
        },
      },
      text: "x",
    },
    {
      range: {
        start: {
          line: 0,
          character: 2,
        },
        end: {
          line: 0,
          character: 2,
        },
      },
      text: "y",
    },
  ];

  assert.equal(prepareIncrementalChanges(before, "abYef", overlapping), null);
  assert.equal(prepareIncrementalChanges(before, "abxycdef", tied), null);
  assert.equal(
    prepareIncrementalChanges(before, "different", [
      {
        range: {
          start: {
            line: 0,
            character: 0,
          },
          end: {
            line: 0,
            character: 1,
          },
        },
        text: "x",
      },
    ]),
    null,
  );
});

test("unpaired surrogates are rejected and valid text still converts around them", () => {
  assert.equal(isWellFormedUtf16("a😀é"), true);
  assert.equal(isWellFormedUtf16("a\ud800"), false);
  assert.equal(isWellFormedUtf16("\udc00"), false);
  assert.throws(() => convertEditorRangeToUtf8("a\ud800", {
    start: {
      line: 0,
      character: 0,
    },
    end: {
      line: 0,
      character: 1,
    },
  }), /unpaired UTF-16 surrogates/);

  assert.throws(() => convertEditorRangeToUtf8("😀", {
    start: {
      line: 0,
      character: 1,
    },
    end: {
      line: 0,
      character: 2,
    },
  }), /splits a UTF-16 surrogate pair/);
});

test("server byte positions reject UTF-8 scalar splits and out-of-content columns", () => {
  const text = "é😀\r\n";
  assert.throws(() => convertUtf8RangeToEditor(text, {
    start: {
      line: 0,
      character: 1,
    },
    end: {
      line: 0,
      character: 2,
    },
  }), /splits a UTF-8 scalar/);

  assert.throws(() => convertUtf8RangeToEditor(text, {
    start: {
      line: 1,
      character: 1,
    },
    end: {
      line: 1,
      character: 1,
    },
  }), /extends past line content/);
});

test("sparse checkpoints preserve Unicode boundaries around the scan interval", () => {
  const text = `${"a".repeat(63)}é😀${"z".repeat(200)}\r\nlast`;
  const mapper = createTextCoordinateMapper(text);
  const editorColumns = [62, 63, 64, 66, 127, 128, 265];

  for (const character of editorColumns) {
    const range = {
      start: {
        line: 0,
        character,
      },
      end: {
        line: 0,
        character,
      },
    };
    const utf8Range = mapper.editorRangeToUtf8(range);
    const converted = mapper.utf8RangeToEditor(utf8Range);

    assert.deepEqual(converted, range);
  }

  assert.throws(() => mapper.editorRangeToUtf8({
    start: {
      line: 0,
      character: 65,
    },
    end: {
      line: 0,
      character: 65,
    },
  }), /splits a UTF-16 surrogate pair/);
});

test("one snapshot mapper converts a large diagnostic batch", () => {
  const lineCount = 2_000;
  const lineText = "value = é😀\r\n";
  const text = lineText.repeat(lineCount);
  const mapper = createTextCoordinateMapper(text);
  const mappedRanges = [];

  for (let line = 0; line < lineCount; line += 1) {
    const range = {
      start: {
        line,
        character: 8,
      },
      end: {
        line,
        character: 11,
      },
    };
    mappedRanges.push(mapper.editorRangeToUtf8(range));
  }

  assert.equal(mappedRanges.length, lineCount);
  for (const mappedRange of mappedRanges) {
    assert.deepEqual(mapper.utf8RangeToEditor(mappedRange).start, {
      line: mappedRange.start.line,
      character: 8,
    });
  }
});

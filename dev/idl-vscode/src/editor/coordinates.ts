export interface EditorPosition {
  readonly line: number;
  readonly character: number;
}

export interface EditorRange {
  readonly start: EditorPosition;
  readonly end: EditorPosition;
}

export interface EditorTextChange {
  readonly range: EditorRange | null;
  readonly text: string;
}

export interface Utf8Position {
  readonly line: number;
  readonly character: number;
}

export interface Utf8Range {
  readonly start: Utf8Position;
  readonly end: Utf8Position;
}

export interface Utf8TextChange {
  readonly range: Utf8Range;
  readonly text: string;
}

interface CoordinateCheckpoint {
  readonly offset: number;
  readonly utf16Column: number;
  readonly utf8ByteColumn: number;
}

interface LineBounds {
  readonly start: number;
  readonly contentEnd: number;
  readonly checkpoints: readonly CoordinateCheckpoint[];
}

interface PositionMapping {
  readonly offset: number;
  readonly position: Utf8Position;
}

interface ScalarStep {
  readonly offset: number;
  readonly utf16Length: number;
  readonly utf8Length: number;
}

interface OffsetChange {
  readonly startOffset: number;
  readonly endOffset: number;
  readonly change: Utf8TextChange;
}

const checkpointIntervalUtf16Units = 64;

export class TextCoordinateMapper {
  readonly text: string;
  private readonly lines: readonly LineBounds[];

  constructor(text: string) {
    requireWellFormedText(text);
    this.text = text;
    this.lines = buildLineBounds(text);
    Object.freeze(this);
  }

  editorRangeToUtf8(range: EditorRange): Utf8Range {
    const start = this.editorPositionToMapping(range.start);
    const end = this.editorPositionToMapping(range.end);
    const rangeIsOrdered = start.offset <= end.offset;
    if (!rangeIsOrdered) {
      throw new Error("The editor change range has reversed endpoints.");
    }

    const converted: Utf8Range = {
      start: start.position,
      end: end.position,
    };

    return converted;
  }

  editorPositionToOffset(position: EditorPosition): number {
    const mapping = this.editorPositionToMapping(position);

    return mapping.offset;
  }

  utf8RangeToEditor(range: Utf8Range): EditorRange {
    const startOffset = this.utf8PositionToOffset(range.start);
    const endOffset = this.utf8PositionToOffset(range.end);
    const rangeIsOrdered = startOffset <= endOffset;
    if (!rangeIsOrdered) {
      throw new Error("The server diagnostic range has reversed endpoints.");
    }

    const start = this.offsetToEditorPosition(range.start.line, startOffset);
    const end = this.offsetToEditorPosition(range.end.line, endOffset);
    const converted: EditorRange = {
      start,
      end,
    };

    return converted;
  }

  private editorPositionToMapping(position: EditorPosition): PositionMapping {
    const line = this.getLine(position.line, "The editor position has an invalid line.");
    const lineLength = line.contentEnd - line.start;
    const characterIsValid =
      Number.isInteger(position.character) &&
      position.character >= 0 &&
      position.character <= lineLength;
    if (!characterIsValid) {
      throw new Error("The editor position has an invalid character offset.");
    }

    const checkpoint = findCheckpointByUtf16Column(line, position.character);
    let offset = checkpoint.offset;
    let utf16Column = checkpoint.utf16Column;
    let utf8ByteColumn = checkpoint.utf8ByteColumn;
    while (utf16Column < position.character) {
      const next = this.nextScalar(offset, line.contentEnd);
      const nextUtf16Column = utf16Column + next.utf16Length;
      const targetSplitsSurrogatePair = position.character < nextUtf16Column;
      if (targetSplitsSurrogatePair) {
        throw new Error("The editor position splits a UTF-16 surrogate pair.");
      }

      offset = next.offset;
      utf16Column = nextUtf16Column;
      utf8ByteColumn += next.utf8Length;
    }

    const positionMapping: PositionMapping = {
      offset,
      position: {
        line: position.line,
        character: utf8ByteColumn,
      },
    };

    return positionMapping;
  }

  private utf8PositionToOffset(position: Utf8Position): number {
    const line = this.getLine(position.line, "The server position has an invalid line.");
    const byteColumnIsValid =
      Number.isInteger(position.character) && position.character >= 0;
    if (!byteColumnIsValid) {
      throw new Error("The server position has an invalid byte column.");
    }

    const checkpoint = findCheckpointByUtf8Column(line, position.character);
    let offset = checkpoint.offset;
    let utf8ByteColumn = checkpoint.utf8ByteColumn;
    while (offset < line.contentEnd) {
      if (utf8ByteColumn === position.character) {
        return offset;
      }

      const next = this.nextScalar(offset, line.contentEnd);
      const nextByteColumn = utf8ByteColumn + next.utf8Length;
      const positionSplitsScalar = position.character < nextByteColumn;
      if (positionSplitsScalar) {
        throw new Error("The server position splits a UTF-8 scalar.");
      }

      offset = next.offset;
      utf8ByteColumn = nextByteColumn;
    }

    const positionIsAtLineEnd = utf8ByteColumn === position.character;
    if (!positionIsAtLineEnd) {
      throw new Error("The server position extends past line content.");
    }

    return line.contentEnd;
  }

  private offsetToEditorPosition(lineNumber: number, offset: number): EditorPosition {
    const line = this.getLine(lineNumber, "The server position has an invalid line.");
    const position: EditorPosition = {
      line: lineNumber,
      character: offset - line.start,
    };

    return position;
  }

  private getLine(lineNumber: number, errorMessage: string): LineBounds {
    const lineNumberIsValid =
      Number.isInteger(lineNumber) && lineNumber >= 0 && lineNumber < this.lines.length;
    if (!lineNumberIsValid) {
      throw new Error(errorMessage);
    }

    const line = this.lines[lineNumber];
    if (line === undefined) {
      throw new Error(errorMessage);
    }

    return line;
  }

  private nextScalar(offset: number, lineEnd: number): ScalarStep {
    const codePoint = this.text.codePointAt(offset);
    const scalarIsWithinLine = codePoint !== undefined && offset < lineEnd;
    if (!scalarIsWithinLine || codePoint === undefined) {
      throw new Error("The text coordinate is outside valid document content.");
    }

    const utf16Length = getUtf16Length(codePoint);
    const utf8Length = getUtf8Length(codePoint);

    const scalar: ScalarStep = {
      offset: offset + utf16Length,
      utf16Length,
      utf8Length,
    };

    return scalar;
  }
}

export function isWellFormedUtf16(text: string): boolean {
  let index = 0;
  while (index < text.length) {
    const codeUnit = text.charCodeAt(index);
    if (isHighSurrogate(codeUnit)) {
      const hasFollowingCodeUnit = index + 1 < text.length;
      if (!hasFollowingCodeUnit) {
        return false;
      }

      const nextCodeUnit = text.charCodeAt(index + 1);
      if (!isLowSurrogate(nextCodeUnit)) {
        return false;
      }

      index += 2;
      continue;
    }

    const isUnpairedLowSurrogate = isLowSurrogate(codeUnit);
    if (isUnpairedLowSurrogate) {
      return false;
    }

    index += 1;
  }

  return true;
}

export function createTextCoordinateMapper(text: string): TextCoordinateMapper {
  const mapper = new TextCoordinateMapper(text);

  return mapper;
}

export function convertEditorRangeToUtf8(text: string, range: EditorRange): Utf8Range {
  const mapper = new TextCoordinateMapper(text);
  const converted = mapper.editorRangeToUtf8(range);

  return converted;
}

export function prepareIncrementalChanges(
  beforeText: string,
  afterText: string,
  changes: readonly EditorTextChange[],
  retainedMapper?: TextCoordinateMapper,
): readonly Utf8TextChange[] | null {
  requireWellFormedText(afterText);
  const beforeMapperIsReusable = retainedMapper !== undefined && retainedMapper.text === beforeText;
  let beforeMapper: TextCoordinateMapper;
  if (beforeMapperIsReusable && retainedMapper !== undefined) {
    beforeMapper = retainedMapper;
  } else {
    beforeMapper = new TextCoordinateMapper(beforeText);
  }

  const convertedChanges: OffsetChange[] = [];
  for (const change of changes) {
    requireWellFormedText(change.text);
    if (change.range === null) {
      return null;
    }

    let range: Utf8Range | null = null;
    try {
      range = beforeMapper.editorRangeToUtf8(change.range);
    } catch {
      return null;
    }

    const startOffset = beforeMapper.editorPositionToOffset(change.range.start);
    const endOffset = beforeMapper.editorPositionToOffset(change.range.end);
    if (startOffset > endOffset) {
      return null;
    }

    const converted: Utf8TextChange = {
      range,
      text: change.text,
    };
    const offsetChange: OffsetChange = {
      startOffset,
      endOffset,
      change: converted,
    };
    convertedChanges.push(offsetChange);
  }

  const descendingChanges = [...convertedChanges].sort((left, right) => {
    return right.startOffset - left.startOffset;
  });
  const changesAreUnambiguous = areChangesUnambiguous(descendingChanges);
  if (!changesAreUnambiguous) {
    return null;
  }

  let reconstructedText = beforeText;
  for (const item of descendingChanges) {
    reconstructedText =
      reconstructedText.slice(0, item.startOffset) +
      item.change.text +
      reconstructedText.slice(item.endOffset);
  }

  const reconstructionMatchesEditor = reconstructedText === afterText;
  if (!reconstructionMatchesEditor) {
    return null;
  }

  const wireChanges = descendingChanges.map((item) => item.change);
  return wireChanges;
}

export function convertUtf8RangeToEditor(text: string, range: Utf8Range): EditorRange {
  const mapper = new TextCoordinateMapper(text);
  const converted = mapper.utf8RangeToEditor(range);

  return converted;
}

function areChangesUnambiguous(changes: readonly OffsetChange[]): boolean {
  let previousStartOffset: number | null = null;
  let previousStartForOverlap: number | null = null;

  for (const item of changes) {
    if (previousStartOffset === item.startOffset) {
      return false;
    }

    if (previousStartForOverlap !== null && item.endOffset > previousStartForOverlap) {
      return false;
    }

    previousStartOffset = item.startOffset;
    previousStartForOverlap = item.startOffset;
  }

  return true;
}

function buildLineBounds(text: string): readonly LineBounds[] {
  const lines: LineBounds[] = [];
  let lineStart = 0;

  while (true) {
    let lineEnd = lineStart;
    while (lineEnd < text.length) {
      const codeUnit = text.charCodeAt(lineEnd);
      const isLineTerminator = codeUnit === 0x000d || codeUnit === 0x000a;
      if (isLineTerminator) {
        break;
      }

      lineEnd += 1;
    }

    const line = buildOneLine(text, lineStart, lineEnd);
    lines.push(line);
    if (lineEnd === text.length) {
      break;
    }

    const isCarriageReturn = text.charCodeAt(lineEnd) === 0x000d;
    const nextIsLineFeed = lineEnd + 1 < text.length && text.charCodeAt(lineEnd + 1) === 0x000a;
    if (isCarriageReturn && nextIsLineFeed) {
      lineStart = lineEnd + 2;
    } else {
      lineStart = lineEnd + 1;
    }

    const hasTrailingEmptyLine = lineStart === text.length;
    if (hasTrailingEmptyLine) {
      lines.push(buildOneLine(text, lineStart, lineStart));
      break;
    }
  }

  const frozenLines = Object.freeze(lines);
  return frozenLines;
}

function buildOneLine(text: string, start: number, contentEnd: number): LineBounds {
  const checkpoints: CoordinateCheckpoint[] = [];
  let offset = start;
  let utf16Column = 0;
  let utf8ByteColumn = 0;
  let lastCheckpointColumn = 0;
  checkpoints.push({
    offset,
    utf16Column,
    utf8ByteColumn,
  });

  while (offset < contentEnd) {
    // A checkpoint at most 65 UTF-16 units away bounds the scan after binary search.
    const checkpointIsDue = utf16Column - lastCheckpointColumn >= checkpointIntervalUtf16Units;
    if (checkpointIsDue) {
      checkpoints.push({
        offset,
        utf16Column,
        utf8ByteColumn,
      });
      lastCheckpointColumn = utf16Column;
    }

    const codePoint = text.codePointAt(offset);
    if (codePoint === undefined) {
      throw new Error("The text coordinate is outside valid document content.");
    }

    const utf16Length = getUtf16Length(codePoint);
    const utf8Length = getUtf8Length(codePoint);
    offset += utf16Length;
    utf16Column += utf16Length;
    utf8ByteColumn += utf8Length;
  }

  const finalCheckpointIsDue = utf16Column - lastCheckpointColumn >= checkpointIntervalUtf16Units;
  if (finalCheckpointIsDue) {
    checkpoints.push({
      offset,
      utf16Column,
      utf8ByteColumn,
    });
  }

  const line: LineBounds = {
    start,
    contentEnd,
    checkpoints: Object.freeze(checkpoints),
  };

  return line;
}

function findCheckpointByUtf16Column(line: LineBounds, column: number): CoordinateCheckpoint {
  let lower = 0;
  let upper = line.checkpoints.length - 1;
  let bestIndex = 0;

  while (lower <= upper) {
    const middle = Math.floor((lower + upper) / 2);
    const checkpoint = line.checkpoints[middle];
    if (checkpoint === undefined) {
      break;
    }

    if (checkpoint.utf16Column <= column) {
      bestIndex = middle;
      lower = middle + 1;
    } else {
      upper = middle - 1;
    }
  }

  const bestCheckpoint = line.checkpoints[bestIndex];
  if (bestCheckpoint === undefined) {
    throw new Error("The text line has no coordinate checkpoint.");
  }

  return bestCheckpoint;
}

function findCheckpointByUtf8Column(line: LineBounds, column: number): CoordinateCheckpoint {
  let lower = 0;
  let upper = line.checkpoints.length - 1;
  let bestIndex = 0;

  while (lower <= upper) {
    const middle = Math.floor((lower + upper) / 2);
    const checkpoint = line.checkpoints[middle];
    if (checkpoint === undefined) {
      break;
    }

    if (checkpoint.utf8ByteColumn <= column) {
      bestIndex = middle;
      lower = middle + 1;
    } else {
      upper = middle - 1;
    }
  }

  const bestCheckpoint = line.checkpoints[bestIndex];
  if (bestCheckpoint === undefined) {
    throw new Error("The text line has no coordinate checkpoint.");
  }

  return bestCheckpoint;
}

function getUtf16Length(codePoint: number): number {
  let utf16Length = 1;
  if (codePoint > 0xffff) {
    utf16Length = 2;
  }

  return utf16Length;
}

function getUtf8Length(codePoint: number): number {
  let utf8Length: number;
  if (codePoint <= 0x7f) {
    utf8Length = 1;
  } else if (codePoint <= 0x7ff) {
    utf8Length = 2;
  } else if (codePoint <= 0xffff) {
    utf8Length = 3;
  } else {
    utf8Length = 4;
  }

  return utf8Length;
}

function requireWellFormedText(text: string): void {
  if (!isWellFormedUtf16(text)) {
    throw new Error("Idle documents must not contain unpaired UTF-16 surrogates.");
  }
}

function isHighSurrogate(codeUnit: number): boolean {
  return codeUnit >= 0xd800 && codeUnit <= 0xdbff;
}

function isLowSurrogate(codeUnit: number): boolean {
  return codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
}

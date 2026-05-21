import std/[tables, strutils]

type
  Annotation* = object
    translation*: string
    vocabulary*: string
    grammar*: string

  Document* = object
    sourcePath*: string
    lines*: seq[string]
    cursor*: int
    cache*: Table[string, Annotation]

  Overlay* = object
    visible*: bool
    loading*: bool
    title*: string
    body*: Annotation
    scroll*: int

  AppState* = object
    doc*: Document
    overlay*: Overlay

proc loadDocument*(path: string): Document =
  let raw = readFile(path)
  var lines: seq[string]
  for line in raw.splitLines():
    let s = line.strip()
    if s.len > 0:
      lines.add(s)
  Document(sourcePath: path, lines: lines, cursor: 0,
           cache: initTable[string, Annotation]())

proc moveCursor*(d: var Document, delta: int) =
  d.cursor = max(0, min(d.lines.len - 1, d.cursor + delta))

proc currentSentence*(d: Document): string =
  if d.lines.len == 0: return ""
  d.lines[d.cursor]

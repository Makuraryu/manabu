import std/[tables, strutils, json]

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
    statusMsg*: string

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

proc saveDocumentJson*(doc: Document, path: string) =
  var cacheObj = newJObject()
  for sentence, ann in doc.cache:
    cacheObj[sentence] = %* {
      "translation": ann.translation,
      "vocabulary": ann.vocabulary,
      "grammar": ann.grammar
    }
  let root = %* {
    "lines": doc.lines,
    "cache": cacheObj
  }
  writeFile(path, root.pretty() & "\n")

proc loadDocumentJson*(path: string): Document =
  let root =
    try: parseFile(path)
    except JsonParsingError as e:
      raise newException(IOError, "JSON 解析失败：" & e.msg)
    except CatchableError as e:
      raise newException(IOError, "读取失败：" & e.msg)
  if root.kind != JObject:
    raise newException(IOError, ".manabu 根节点必须是 JSON object")
  if not root.hasKey("lines") or root["lines"].kind != JArray:
    raise newException(IOError, ".manabu 缺少 lines 数组")
  var lines: seq[string]
  for item in root["lines"]:
    if item.kind != JString:
      raise newException(IOError, "lines 元素必须是字符串")
    lines.add(item.getStr())
  var cache = initTable[string, Annotation]()
  if root.hasKey("cache"):
    if root["cache"].kind != JObject:
      raise newException(IOError, "cache 必须是 JSON object")
    for sentence, node in root["cache"].pairs:
      if node.kind != JObject:
        raise newException(IOError, "cache 项必须是 object")
      cache[sentence] = Annotation(
        translation: if node.hasKey("translation"): node["translation"].getStr() else: "",
        vocabulary:  if node.hasKey("vocabulary"):  node["vocabulary"].getStr()  else: "",
        grammar:     if node.hasKey("grammar"):     node["grammar"].getStr()     else: ""
      )
  Document(sourcePath: path, lines: lines, cursor: 0, cache: cache)

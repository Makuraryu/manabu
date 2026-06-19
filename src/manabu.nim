import std/[os, osproc, streams, strutils, tables]
import illwill
import types
import api
import ui
import input

proc getOrFetch(state: var AppState, cfg: Config, sentence: string): Annotation =
  if state.doc.cache.hasKey(sentence):
    return state.doc.cache[sentence]
  let ann = requestAnnotation(cfg, sentence)
  state.doc.cache[sentence] = ann
  ann

proc copyToClipboard(text: string) =
  let p = startProcess("pbcopy", options = {poUsePath})
  p.inputStream.write(text)
  close(p.inputStream)
  discard p.waitForExit()
  p.close()

proc exportSession(doc: Document, outPath: string) =
  if doc.cache.len == 0:
    return
  saveDocumentJson(doc, outPath)

proc safeTermSize(): tuple[w, h: int] =
  (max(40, terminalWidth()), max(10, terminalHeight()))

proc main() =
  let params = commandLineParams()
  var parseMode = false
  var positional: seq[string]
  for p in params:
    if p == "--parse": parseMode = true
    else: positional.add(p)
  if positional.len == 0:
    stderr.writeLine("用法：manabu [--parse] <文件路径>")
    quit(1)
  let path = positional[0]
  if not fileExists(path):
    stderr.writeLine("错误：文件不存在：" & path)
    quit(1)

  let cfg = loadConfig()
  let sessionSibling = path.changeFileExt("manabu")
  let actualPath =
    if path.splitFile().ext.toLowerAscii() != ".manabu" and fileExists(sessionSibling):
      sessionSibling
    else:
      path
  let isSession = actualPath.splitFile().ext.toLowerAscii() == ".manabu"
  var state = AppState(overlay: Overlay(visible: false))
  try:
    state.doc =
      if parseMode: loadDocumentParsed(path)
      elif isSession: loadDocumentJson(actualPath)
      else: loadDocument(actualPath)
  except IOError as e:
    stderr.writeLine("错误：" & e.msg)
    quit(1)
  if state.doc.lines.len == 0:
    stderr.writeLine("错误：文件中没有有效行")
    quit(1)

  # Manage alternate screen ourselves so behaviour is consistent across all
  # terminal types, regardless of $TERM (illwill's fullScreen branches on $TERM
  # and falls back to eraseScreen which dumps blank lines into scroll history).
  stdout.write("\e[?1049h\e[H")
  stdout.flushFile()
  illwillInit(fullScreen = false)
  hideCursor()
  enableMouseTracking()

  proc cleanup() {.noconv.} =
    disableMouseTracking()
    stdout.write("\e[?1049l")
    stdout.flushFile()
    try: illwillDeinit() except IllwillError: discard
    showCursor()
    stdout.flushFile()
    quit(0)

  setControlCHook(cleanup)

  defer:
    disableMouseTracking()
    stdout.write("\e[?1049l")
    stdout.flushFile()
    try: illwillDeinit() except IllwillError: discard
    showCursor()
    exportSession(state.doc, path.changeFileExt("manabu"))

  var dirty = true
  var lastW = 0
  var lastH = 0

  while true:
    let (tw, th) = safeTermSize()
    if tw != lastW or th != lastH:
      lastW = tw; lastH = th
      dirty = true
    if dirty:
      render(state, tw, th)
      dirty = false

    let key = getInput()
    if key == Key.None:
      sleep(20)
      continue

    dirty = true
    state.statusMsg = ""
    case key
    of Key.Q:
      break
    of Key.Escape:
      if state.overlay.visible:
        state.overlay = Overlay(visible: false)
    of Key.Up, Key.K:
      if state.overlay.visible:
        if not state.overlay.loading and state.overlay.scroll > 0:
          dec state.overlay.scroll
      else:
        moveCursor(state.doc, -1)
    of Key.Down, Key.J:
      if state.overlay.visible:
        if not state.overlay.loading:
          inc state.overlay.scroll
      else:
        moveCursor(state.doc, +1)
    of Key.Left:
      if not state.overlay.visible:
        moveCursor(state.doc, -1)
    of Key.Right:
      if not state.overlay.visible:
        moveCursor(state.doc, +1)
    of Key.Mouse:
      case input.gScrollDir
      of ScrollDir.sdUp:
        if state.overlay.visible:
          if not state.overlay.loading and state.overlay.scroll > 0:
            dec state.overlay.scroll
        else:
          moveCursor(state.doc, -1)
      of ScrollDir.sdDown:
        if state.overlay.visible:
          if not state.overlay.loading:
            inc state.overlay.scroll
        else:
          moveCursor(state.doc, +1)
      of ScrollDir.sdNone:
        dirty = false
    of Key.Enter:
      if state.overlay.visible:
        state.overlay = Overlay(visible: false)
      else:
        let s = currentSentence(state.doc)
        if state.doc.cache.hasKey(s):
          state.overlay = Overlay(visible: true, loading: false,
                                   title: s, body: state.doc.cache[s])
        else:
          state.overlay = Overlay(visible: true, loading: true, title: s)
          let (tw2, th2) = safeTermSize()
          render(state, tw2, th2)
          let ann = getOrFetch(state, cfg, s)
          state.overlay = Overlay(visible: true, loading: false,
                                   title: s, body: ann)
    of Key.R:
      let s = currentSentence(state.doc)
      state.doc.cache.del(s)
      state.overlay = Overlay(visible: true, loading: true, title: s)
      let (tw2, th2) = safeTermSize()
      render(state, tw2, th2)
      let ann = getOrFetch(state, cfg, s)
      state.overlay = Overlay(visible: true, loading: false, title: s, body: ann)
    of Key.C:
      copyToClipboard(currentSentence(state.doc))
      state.statusMsg = "已复制"
    else:
      if state.overlay.visible:
        state.overlay = Overlay(visible: false)

main()

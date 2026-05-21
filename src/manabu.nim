import std/[os, strutils, tables]
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

proc exportSession(doc: Document, outPath: string) =
  if doc.cache.len == 0:
    return
  saveDocumentJson(doc, outPath)

proc safeTermSize(): tuple[w, h: int] =
  (max(40, terminalWidth()), max(10, terminalHeight()))

proc main() =
  let params = commandLineParams()
  if params.len == 0:
    stderr.writeLine("用法：manabu <文件路径>")
    quit(1)
  let path = params[0]
  if not fileExists(path):
    stderr.writeLine("错误：文件不存在：" & path)
    quit(1)

  let cfg = loadConfig()
  let isSession = path.splitFile().ext.toLowerAscii() == ".manabu"
  var state = AppState(overlay: Overlay(visible: false))
  try:
    state.doc =
      if isSession: loadDocumentJson(path)
      else: loadDocument(path)
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
    else:
      if state.overlay.visible:
        state.overlay = Overlay(visible: false)

main()

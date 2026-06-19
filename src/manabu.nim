import std/[os, osproc, streams, strutils, tables, times]
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

proc exportSession(doc: Document, outPath: string, force = false) =
  if doc.cache.len == 0 and not force:
    return
  saveDocumentJson(doc, outPath)

proc composeViaEditor(): string =
  ## Open $VISUAL/$EDITOR (fallback vi) on a temp file and return the typed text.
  ## A non-zero editor exit (e.g. vim :cq) is treated as a cancel => "".
  let ts = now().format("yyyyMMdd-HHmmss")
  let tmp = getTempDir() / ("manabu-" & ts & ".txt")
  writeFile(tmp, "")
  var editor = getEnv("VISUAL")
  if editor.len == 0: editor = getEnv("EDITOR")
  if editor.len == 0: editor = "vi"
  let parts = parseCmdLine(editor)          # handles e.g. "code --wait"
  let exe = parts[0]
  let args = parts[1 .. ^1] & tmp
  let p = startProcess(exe, args = args, options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  p.close()
  result = if code == 0: readFile(tmp) else: ""
  removeFile(tmp)

proc safeTermSize(): tuple[w, h: int] =
  (max(40, terminalWidth()), max(10, terminalHeight()))

proc main() =
  let params = commandLineParams()
  var parseMode = false
  var positional: seq[string]
  for p in params:
    if p == "--parse": parseMode = true
    else: positional.add(p)
  # No file argument → compose mode: type text in $EDITOR, always sentence-split,
  # and save to a timestamped .manabu in the current directory.
  let composeMode = positional.len == 0
  var path: string
  var composeText: string
  if composeMode:
    path = getCurrentDir() / (now().format("yyyyMMdd-HHmmss") & ".manabu")
    composeText = composeViaEditor()
    if composeText.strip().len == 0:
      stderr.writeLine("未输入任何内容，已取消")
      quit(0)
  else:
    path = positional[0]
    if not fileExists(path):
      stderr.writeLine("错误：文件不存在：" & path)
      quit(1)

  let cfg = loadConfig()
  var actualPath = path
  var isSession = false
  if not composeMode:
    let sessionSibling = path.changeFileExt("manabu")
    actualPath =
      if path.splitFile().ext.toLowerAscii() != ".manabu" and fileExists(sessionSibling):
        sessionSibling
      else:
        path
    isSession = actualPath.splitFile().ext.toLowerAscii() == ".manabu"
  var state = AppState(overlay: Overlay(visible: false))
  try:
    state.doc =
      if composeMode: documentFromText(composeText, path, parse = true)
      elif parseMode: loadDocumentParsed(path)
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
    let outPath = path.changeFileExt("manabu")
    exportSession(state.doc, outPath, force = composeMode)
    if composeMode and fileExists(outPath):
      stdout.writeLine("已保存到 " & outPath)

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

import std/[strutils, unicode]
import types

const indent = "        "  # 8 spaces

# ---------------------------------------------------------------------------
# Display-width helpers (CJK full-width = 2 cols, others = 1)
# ---------------------------------------------------------------------------

proc displayWidth*(s: string): int =
  for r in runes(s):
    let cp = ord(r)
    if (cp >= 0x1100 and cp <= 0x115F) or
       (cp >= 0x2E80 and cp <= 0x303F) or
       (cp >= 0x3040 and cp <= 0xA4CF) or
       (cp >= 0xAC00 and cp <= 0xD7A3) or
       (cp >= 0xF900 and cp <= 0xFAFF) or
       (cp >= 0xFE10 and cp <= 0xFE6F) or
       (cp >= 0xFF01 and cp <= 0xFF60) or
       (cp >= 0xFFE0 and cp <= 0xFFE6):
      result += 2
    else:
      result += 1

proc truncateByWidth*(s: string, maxW: int): string =
  if displayWidth(s) <= maxW: return s
  var w = 0; var i = 0
  while i < s.len:
    let size = runeLenAt(s, i)
    let rw = displayWidth($runeAt(s, i))
    if w + rw > maxW - 1: break
    w += rw; i += size
  s[0 ..< i] & "…"

proc pad*(s: string, targetW: int): string =
  let dw = displayWidth(s)
  if dw >= targetW: return s
  s & spaces(targetW - dw)

proc clipByCols*(s: string, fromCol, toCol: int): string =
  ## Slice `s` down to the cells covering display columns [fromCol, toCol).
  ## A double-width rune straddling either boundary is replaced by spaces for
  ## the columns that fall inside the region, so callers never emit half of a
  ## wide glyph at the region's edge.
  var col = 0; var i = 0
  while i < s.len and col < toCol:
    let size = runeLenAt(s, i)
    let rw = displayWidth($runeAt(s, i))
    if col >= fromCol and col + rw <= toCol:
      result.add(s[i ..< i + size])
    elif col + rw > fromCol:
      for _ in max(col, fromCol) ..< min(col + rw, toCol):
        result.add(' ')
    col += rw
    i += size

proc wrapByWidth*(s: string, maxW: int): seq[string] =
  for line in s.splitLines():
    if line.strip() == "": result.add(""); continue
    if displayWidth(line) <= maxW: result.add(line); continue
    var cur = line
    while displayWidth(cur) > maxW:
      var w = 0; var i = 0
      while i < cur.len:
        let size = runeLenAt(cur, i)
        let rw = displayWidth($runeAt(cur, i))
        if w + rw > maxW: break
        w += rw; i += size
      result.add(cur[0 ..< i])
      cur = cur[i .. ^1]
    if cur.len > 0: result.add(cur)

# ---------------------------------------------------------------------------
# Direct ANSI rendering — no illwill TerminalBuffer
# One frame = one string, written atomically to avoid partial-frame flicker.
# "\e[H" moves cursor to top-left without clearing; every cell is overwritten
# so old content never shows through.
# ---------------------------------------------------------------------------

proc at(row, col: int): string =
  "\e[" & $(row + 1) & ";" & $(col + 1) & "H"

proc render*(state: AppState, w, h: int) =
  var buf = newStringOfCap(w * h * 16)
  buf &= "\e[H"  # cursor home; overwrite in place — no clear flash

  # --- List rows (rows 0..h-2) with wrapping ---
  let anchorRow = h div 3
  let cursor = state.doc.cursor

  var rows = newSeq[tuple[text: string, selected: bool]](h - 1)

  let selWrapped = wrapByWidth(state.doc.lines[cursor], w)
  for i in 0 ..< selWrapped.len:
    let r = anchorRow + i
    if r < h - 1:
      rows[r] = (selWrapped[i], true)

  # Fill rows below selected sentence
  var fillRow = anchorRow + selWrapped.len
  var lineIdx = cursor + 1
  while fillRow < h - 1 and lineIdx < state.doc.lines.len:
    for wl in wrapByWidth(state.doc.lines[lineIdx], w):
      if fillRow < h - 1:
        rows[fillRow] = (wl, false)
        inc fillRow
    inc lineIdx

  # Fill rows above selected sentence (reverse: last wrap line nearest cursor)
  fillRow = anchorRow - 1
  lineIdx = cursor - 1
  while fillRow >= 0 and lineIdx >= 0:
    let wrapped = wrapByWidth(state.doc.lines[lineIdx], w)
    for j in countdown(wrapped.len - 1, 0):
      if fillRow >= 0:
        rows[fillRow] = (wrapped[j], false)
        dec fillRow
    dec lineIdx

  # --- Overlay geometry, computed before list rows are emitted ---
  # List rows underneath the overlay must not draw a double-width glyph
  # straddling the overlay's edge: the overlay would overwrite one half and
  # the terminal blanks the orphaned half-cell, leaving stray cells beside
  # the borders. So rows covered by the overlay are clipped around it.
  const loadingMsg = "  解析中，请稍候…  "
  var ovTop, ovBottom = -1        # inclusive row range covered by the overlay
  var ovLeft, ovRight = 0         # column range [ovLeft, ovRight)
  var ovX, ovY, ovW, ovH, innerW, textW = 0
  var titleLines, content: seq[string]
  if state.overlay.visible:
    if state.overlay.loading:
      ovTop = h div 2
      ovBottom = ovTop
      ovLeft = max(0, (w - displayWidth(loadingMsg)) div 2)
      ovRight = min(w, ovLeft + displayWidth(loadingMsg))
    else:
      ovW = min(w - 4, 80)
      if ovW >= 20:
        ovX = max(0, (w - ovW) div 2)
        innerW = ovW - 2          # usable width between borders
        textW = innerW - 8        # width for indented text (8-space indent)

        # Wrap title across multiple lines
        titleLines = wrapByWidth(state.overlay.title, innerW - 2)

        # Build content lines; indent wrapping uses textW so indent+text <= innerW
        content.add("【翻译】")
        for l in wrapByWidth(state.overlay.body.translation, textW):
          content.add(indent & l)
        content.add("")
        content.add("【词汇】")
        for l in wrapByWidth(state.overlay.body.vocabulary, textW):
          content.add(indent & l)
        content.add("")
        content.add("【文法】")
        for l in wrapByWidth(state.overlay.body.grammar, textW):
          content.add(indent & l)

        # Layout: top(1) + titleLines + sep(1) + content + bottom(1)
        ovH = min(titleLines.len + 3 + content.len, h - 2)
        ovY = max(0, (h - ovH) div 2)
        ovTop = ovY
        ovBottom = ovY + ovH - 1
        ovLeft = ovX
        ovRight = ovX + ovW

  for r in 0 ..< h - 1:
    let style =
      if rows[r].selected: "\e[31;1m"
      elif rows[r].text == "": "\e[0m"
      else: "\e[37m"
    let line = pad(rows[r].text, w)
    if r >= ovTop and r <= ovBottom:
      buf &= at(r, 0) & style & clipByCols(line, 0, ovLeft) &
             at(r, ovRight) & clipByCols(line, ovRight, w) & "\e[0m"
    else:
      buf &= at(r, 0) & style & line & "\e[0m"

  # --- Status bar (last row) ---
  buf &= at(h - 1, 0)
  let hints = " ↑↓ 移动   Enter 分析   r 重跑   c 复制   q 退出"
  let rightSide =
    if state.statusMsg != "": "  " & state.statusMsg & "  "
    else: "  " & $(state.doc.cursor + 1) & "/" & $state.doc.lines.len
  let statusRaw = hints & rightSide
  buf &= "\e[47m\e[30m" & pad(truncateByWidth(statusRaw, w), w) & "\e[0m"

  # --- Overlay ---
  if state.overlay.visible:
    if state.overlay.loading:
      buf &= at(h div 2, ovLeft) & "\e[40m\e[33;1m" & loadingMsg & "\e[0m"
    else:
      if ovW >= 20:
        let sepRow = ovY + 1 + titleLines.len
        let maxRows = ovH - titleLines.len - 3

        let visScroll = min(state.overlay.scroll, max(0, content.len - maxRows))

        # 1. Flood-fill entire overlay area with black bg first
        for row in ovY ..< ovY + ovH:
          buf &= at(row, ovX) & "\e[40m\e[37m" & spaces(ovW)

        # 2. Top border
        buf &= at(ovY, ovX) &
               "\e[40m\e[37m" & "┌" & "─".repeat(ovW - 2) & "┐"

        # 3. Side borders
        for row in ovY + 1 ..< ovY + ovH - 1:
          buf &= at(row, ovX)           & "\e[40m\e[37m│"
          buf &= at(row, ovX + ovW - 1) & "\e[40m\e[37m│"

        # 4. Bottom border
        buf &= at(ovY + ovH - 1, ovX) &
               "\e[40m\e[37m" & "└" & "─".repeat(ovW - 2) & "┘"

        # 5. Title rows (wrapped, yellow)
        for i in 0 ..< titleLines.len:
          buf &= at(ovY + 1 + i, ovX + 2) &
                 "\e[40m\e[33;1m" & titleLines[i]

        # 6. Separator with scroll/close hint
        let sepHint = if content.len > maxRows: " ↑↓ 滚动  任意键关闭 "
                      else: " 任意键关闭 "
        let sepHintW = displayWidth(sepHint)
        let totalDash = max(0, ovW - 2 - sepHintW)
        let leftDash = totalDash div 2
        let rightDash = totalDash - leftDash
        buf &= at(sepRow, ovX) &
               "\e[40m\e[37m├" & "─".repeat(leftDash) &
               "\e[36m" & sepHint &
               "\e[37m" & "─".repeat(rightDash) & "┤"

        # 7. Content (scrolled window)
        for i in 0 ..< maxRows:
          let ci = visScroll + i
          let line = if ci < content.len: content[ci] else: ""
          buf &= at(sepRow + 1 + i, ovX + 1) &
                 "\e[40m\e[37m" & pad(truncateByWidth(line, innerW), innerW)

        buf &= "\e[0m"

  stdout.write(buf)
  stdout.flushFile()

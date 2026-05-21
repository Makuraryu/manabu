## Custom stdin reader: regular keys + SGR mouse scroll events.
## illwill's parseStdin (POSIX) discards \e[< sequences — fillGlobalMouseInfo
## is defined but never called. We bypass getKey() and read stdin directly.
## illwill is kept only for: raw-mode init, hideCursor/showCursor, Key enum.
##
## We inline the few C primitives we need instead of `import posix` because
## posix.nim exports its own `Key` type that collides with illwill.Key.

import illwill

# ---------------------------------------------------------------------------
# Minimal C imports (avoids the posix.Key / illwill.Key name collision)
# ---------------------------------------------------------------------------

type
  CTimeval {.importc: "struct timeval", header: "<sys/time.h>", pure.} = object
    tv_sec:  clong
    tv_usec: clong
  CFdSet {.importc: "fd_set", header: "<sys/select.h>", pure.} = object

proc c_read(fd: cint, buf: pointer, count: csize_t): cint {.
  importc: "read", header: "<unistd.h>", sideEffect.}
proc c_select(nfds: cint, r, w, e: ptr CFdSet, tv: ptr CTimeval): cint {.
  importc: "select", header: "<sys/select.h>", sideEffect.}
proc fd_zero(s: var CFdSet) {.importc: "FD_ZERO", header: "<sys/select.h>".}
proc fd_set(fd: cint, s: var CFdSet) {.importc: "FD_SET", header: "<sys/select.h>".}

const STDIN_FD = cint(0)

# ---------------------------------------------------------------------------
# Low-level byte reads
# ---------------------------------------------------------------------------

proc tryReadByte(): int =
  var c: char
  if c_read(STDIN_FD, addr c, 1) == 1: int(uint8(c))
  else: -1

proc readByteTimeout(usec: clong): int =
  var tv = CTimeval(tv_sec: 0, tv_usec: usec)
  var fds: CFdSet
  fd_zero(fds)
  fd_set(STDIN_FD, fds)
  if c_select(STDIN_FD + 1, addr fds, nil, nil, addr tv) > 0:
    var c: char
    if c_read(STDIN_FD, addr c, 1) == 1: return int(uint8(c))
  return -1

proc sb(): int = readByteTimeout(50_000)  # 50 ms — enough for escape sequences

# ---------------------------------------------------------------------------
# SGR mouse scroll parser  (called after \e[< is consumed)
# Format: Cb;Cx;Cy M|m   —  button 64 = scroll up, 65 = scroll down
# ---------------------------------------------------------------------------

type ScrollDir* = enum sdNone, sdUp, sdDown
var gScrollDir*: ScrollDir = sdNone

proc parseSGRMouse(): ScrollDir =
  var nums = [0, 0, 0]
  var part = 0
  for _ in 0 ..< 64:
    let b = sb()
    if b < 0: break
    let c = char(b)
    if c in {'0'..'9'}:
      nums[part] = nums[part] * 10 + (b - int('0'))
    elif c == ';':
      inc part
      if part > 2: break
    elif c == 'M' or c == 'm':
      break
    else:
      break
  case nums[0]
  of 64: sdUp
  of 65: sdDown
  else:  sdNone

# ---------------------------------------------------------------------------
# Key lookups via case statements (avoids {.pure.} enum array-literal issues)
# ---------------------------------------------------------------------------

proc lookupEscBracket(c: char): illwill.Key =
  case c
  of 'A': illwill.Key.Up
  of 'B': illwill.Key.Down
  of 'C': illwill.Key.Right
  of 'D': illwill.Key.Left
  of 'F': illwill.Key.End
  of 'H': illwill.Key.Home
  else:   illwill.Key.None

proc lookupEscO(c: char): illwill.Key =
  case c
  of 'A': illwill.Key.Up
  of 'B': illwill.Key.Down
  of 'C': illwill.Key.Right
  of 'D': illwill.Key.Left
  of 'F': illwill.Key.End
  of 'H': illwill.Key.Home
  of 'P': illwill.Key.F1
  of 'Q': illwill.Key.F2
  of 'R': illwill.Key.F3
  of 'S': illwill.Key.F4
  else:   illwill.Key.None

proc lookupF1Seq(c: char): illwill.Key =
  case c
  of '1': illwill.Key.F1
  of '2': illwill.Key.F2
  of '3': illwill.Key.F3
  of '4': illwill.Key.F4
  of '5': illwill.Key.F5
  of '7': illwill.Key.F6
  of '8': illwill.Key.F7
  of '9': illwill.Key.F8
  else:   illwill.Key.None

proc lookupF2Seq(c: char): illwill.Key =
  case c
  of '0': illwill.Key.F9
  of '1': illwill.Key.F10
  of '3': illwill.Key.F11
  of '4': illwill.Key.F12
  else:   illwill.Key.None

proc lookupTildeSeq(c: char): illwill.Key =
  case c
  of '3': illwill.Key.Delete
  of '4': illwill.Key.End
  of '5': illwill.Key.PageUp
  of '6': illwill.Key.PageDown
  of '7': illwill.Key.Home
  of '8': illwill.Key.End
  else:   illwill.Key.None

# ---------------------------------------------------------------------------
# Mouse tracking control
# ---------------------------------------------------------------------------

proc enableMouseTracking*() =
  ## X10 basic (1000) + SGR extended coordinates (1006).
  ## 1000 reports clicks and scroll; omitting 1003 avoids move-event floods.
  stdout.write("\e[?1000h\e[?1006h")
  stdout.flushFile()

proc disableMouseTracking*() =
  stdout.write("\e[?1000l\e[?1006l")
  stdout.flushFile()

# ---------------------------------------------------------------------------
# Public input reader
# ---------------------------------------------------------------------------

proc getInput*(): illwill.Key =
  ## Non-blocking. Returns Key.None when stdin is empty.
  ## On scroll events sets gScrollDir and returns Key.Mouse.
  gScrollDir = sdNone

  let b1 = tryReadByte()
  if b1 < 0: return illwill.Key.None

  if b1 != 0x1B:
    case b1
    of 8, 127: return illwill.Key.Backspace
    of 10, 13: return illwill.Key.Enter
    else:
      if b1 < 0 or b1 > 127: return illwill.Key.None
      {.push warning[HoleEnumConv]: off.}
      let k = illwill.Key(b1)
      {.pop.}
      return k

  let b2 = sb()
  if b2 < 0: return illwill.Key.Escape

  if b2 == int('O'):
    let b3 = sb()
    if b3 < 0: return illwill.Key.None
    return lookupEscO(char(b3))

  if b2 != int('['):
    return illwill.Key.None

  let b3 = sb()
  if b3 < 0: return illwill.Key.None
  let c3 = char(b3)

  if c3 == '<':
    let dir = parseSGRMouse()
    if dir != sdNone:
      gScrollDir = dir
      return illwill.Key.Mouse
    return illwill.Key.None

  let simple = lookupEscBracket(c3)
  if simple != illwill.Key.None: return simple

  let b4 = sb()
  if b4 < 0: return illwill.Key.None
  let c4 = char(b4)

  if c3 == '1':
    if c4 == '~': return illwill.Key.Home
    let fkey = lookupF1Seq(c4)
    if fkey != illwill.Key.None:
      if sb() == int('~'): return fkey
    return illwill.Key.None

  if c3 == '2':
    if c4 == '~': return illwill.Key.Insert
    let fkey = lookupF2Seq(c4)
    if fkey != illwill.Key.None:
      if sb() == int('~'): return fkey
    return illwill.Key.None

  if c4 == '~':
    return lookupTildeSeq(c3)

  return illwill.Key.None

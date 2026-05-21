# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

```sh
nimble build              # debug build → ./manabu
nimble build -d:release   # release build (what CI ships)
./manabu path/to/text.txt # run against a .txt or .md file
```

There is no test suite and no lint config. CI (`.github/workflows/ci.yml`) only runs `nimble build --accept` on macOS. Releases are tag-driven (`v*`) and additionally update the Homebrew tap at `Makuraryu/homebrew-tap` — see `.github/workflows/release.yml`.

Runtime requires `~/.config/manabu/config.toml` with an `api_key` field (DeepSeek-compatible OpenAI chat-completions endpoint). `base_url` and `model` are optional overrides.

`config.nims` globally enables `-d:ssl` so `httpclient` can talk HTTPS — keep it if you add new build entry points.

## Architecture

Single-binary TUI. Five source files under `src/`, no sub-packages:

- `manabu.nim` — entry point and event loop. Owns the alternate-screen lifecycle (see below), the dirty-flag render gate, and key dispatch.
- `types.nim` — `Document`, `Annotation`, `Overlay`, `AppState`. `loadDocument` strips blank lines so `cursor` always indexes a non-empty line.
- `api.nim` — `loadConfig` (TOML), `requestAnnotation` (synchronous HTTPS POST to `/chat/completions`), `parseResponse` (splits the model output on `###TRANSLATION###` / `###VOCABULARY###` / `###GRAMMAR###` markers). The system prompt enforces that exact three-section format — changing the prompt and the parser must stay in lockstep.
- `ui.nim` — renders one frame as a single ANSI-encoded string written atomically to stdout. Does **not** use illwill's `TerminalBuffer`. CJK-aware width math (`displayWidth`, `truncateByWidth`, `pad`, `wrapByWidth`) treats full-width glyphs as 2 columns; every layout calculation flows through these helpers.
- `input.nim` — custom non-blocking stdin reader. illwill is kept only for raw-mode init, cursor show/hide, and the `Key` enum; key parsing and SGR mouse-scroll parsing (`\e[<…M/m`) are reimplemented because illwill's POSIX `parseStdin` discards mouse sequences. `gScrollDir` is a module-level global set as a side effect of returning `Key.Mouse` — `manabu.nim` reads it immediately after dispatch.

### Terminal lifecycle (don't break this)

`manabu.nim:57-80` deliberately manages the alternate screen itself with raw `\e[?1049h` / `\e[?1049l` instead of `illwill.fullScreen=true`. illwill's full-screen path branches on `$TERM` and on some terminals falls back to `eraseScreen`, which leaves blank lines in scroll history. The cleanup runs from both `setControlCHook` (Ctrl-C) and a `defer` block — both paths must restore mouse mode, exit the alt screen, and call `illwillDeinit`. If you add new exit paths, route them through the same teardown.

### Render model

The loop only repaints when `dirty == true`. Dirtiness is set on: any non-`None` key, terminal resize. Idle ticks `sleep(20)`. `render` rebuilds the whole frame into one `string` and issues a single `stdout.write` — partial frames flicker, so don't break this into multiple writes. Cursor home (`\e[H`) without an erase relies on every cell being overwritten; if you add conditional drawing, ensure all cells in the frame are still written.

### Caching, export & session round-trip

`AppState.doc.cache: Table[string, Annotation]` is keyed by the exact sentence string. On `Enter`, `getOrFetch` consults the cache before hitting the API.

On exit, `exportSession` calls `saveDocumentJson` (defined in [src/types.nim](src/types.nim)) to write a JSON session file:

```json
{ "lines": [...], "cache": { "<sentence>": { "translation": "...", "vocabulary": "...", "grammar": "..." } } }
```

The output path is `path.changeFileExt("manabu")` — so `notes.txt` → `notes.manabu`, `notes.md` → `notes.manabu`, and an input that's already `notes.manabu` overwrites itself. Empty caches are still skipped (no file created).

CLI dispatch: `manabu.nim:main` checks the input extension. `.manabu` (case-insensitive) routes to `loadDocumentJson`, restoring `lines` + `cache` (cursor resets to 0); anything else stays on the plain-text `loadDocument` path. `loadDocumentJson` raises `IOError` on malformed JSON / missing fields / wrong types; `main` catches and exits with a Chinese error message before entering the TUI, so corrupt files don't pollute scroll history.

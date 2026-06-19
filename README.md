# manabu（学ぶ）

A terminal-based Japanese reading tool. Load a `.txt` or `.md` file, navigate sentence by sentence, and press **Enter** to get an instant analysis powered by the DeepSeek API:

- **【翻译】** Natural Chinese translation
- **【词汇】** Per-word breakdown with furigana reading
- **【文法】** Key grammar points and sentence patterns

Analyses are cached in memory for the session and exported to `<file>.manabu` on exit.

## Install

```sh
brew tap Makuraryu/tap
brew install manabu
```

## Setup

Create `~/.config/manabu/config.toml`:

```toml
api_key = "sk-your-deepseek-key"
# model   = "deepseek-chat"   # optional override
# base_url = "https://api.deepseek.com"
```

Get a key at <https://platform.deepseek.com>.

## Usage

```sh
manabu your-text.txt
manabu --parse your-text.txt   # split into sentences on 。！？
```

By default each non-empty line is one navigable entry. With `--parse`, manabu
reads the whole file as one stream (ignoring line breaks) and splits it into
sentences on Japanese terminators `。`, `！`, `？` — useful for prose that packs
several sentences on a line or wraps one sentence across many.

| Key | Action |
|-----|--------|
| `↑` / `↓` / `j` / `k` | Move between sentences |
| Two-finger scroll | Move between sentences / scroll analysis |
| `Enter` | Analyse selected sentence |
| `↑` / `↓` (in analysis) | Scroll long analysis |
| `Esc` / `Enter` / any key | Close analysis |
| `q` | Quit (saves `.manabu` export) |

## Build from source

```sh
brew install nim
git clone https://github.com/Makuraryu/manabu
cd manabu
nimble build -d:release
```

## License

MIT

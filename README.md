# ycm.lua

**The YouCompleteMe typing experience, reborn as a pure-Lua Neovim plugin.**

No Python. No ycmd server. No Rust build step. Just drop it in and type — the
completion menu behaves exactly the way your muscle memory remembers from YCM.

> **⚠️ Use at your own risk.** This is a personal-preference plugin, written
> to scratch exactly one person's itch. The entire codebase was produced by an
> AI agent mechanically porting YouCompleteMe's implementation to Lua. It is
> young, barely battle-tested, and maintained only when its author feels the
> itch again. If you are not that person, you probably want
> [blink.cmp](https://github.com/saghen/blink.cmp) instead.

```lua
-- that's it, completion works out of the box
require('ycm').setup()
```

## Why?

Modern completion plugins (nvim-cmp, blink.cmp) are powerful, but they don't
*feel* like YouCompleteMe. YCM's magic was never any single feature — it was
the details: subsequence matching with smart case, the ranking that always
seems to read your mind, the menu that never steals your first selection.

ycm.lua is a faithful reimplementation of those details, ported line-by-line
from YCM's own source (ycm_core's `Candidate.cpp`/`Result.cpp`, ycmd's
identifier completer, and the Vimscript orchestration in
`autoload/youcompleteme.vim`).

## The YCM feel, faithfully ported

- **Subsequence + smart-case matching** — `fb` matches `FooBar`; lowercase
  queries ignore case, uppercase letters in the query only match uppercase
- **YCM's exact ranking chain** — first-char match → word-boundary matches →
  prefix → match compactness → shorter → lowercase-first. Yes, `FB` finds
  `FooBar`; yes, shorter candidates win ties
- **The menu never auto-selects** — `menuone`+`noselect`, items tagged
  `equal=1` so Vim's own filtering stays out of the way
- **`<Tab>`/`<S-Tab>` to navigate, `<C-y>` to accept** — and accepting won't
  reopen the menu (the classic YCM trick)
- **`<C-n>`/`<C-p>` never re-filters** — selection changes don't retrigger
  completion
- **Semantic completion only on triggers** — `.`, `->`, `::` (per filetype) or
  `<C-Space>`; plain typing gives you lightning-fast identifier completion
  from all open buffers, exactly like YCM
- **Learns as you type** — identifiers you just finished typing become
  candidates instantly; comment/string contents are ignored by default
- **Auto-import works** — selecting a candidate with `additionalTextEdits`
  applies the edit (e.g. pyright's `Auto-import` entries)
- **Path completion** — type `./`, `../`, `~/` or anything containing `/`

Semantic completion uses Neovim's built-in LSP client — any server you already
have configured just works.

## Install

lazy.nvim:

```lua
{
  'r1cardohj/ycm.lua',
  name = 'ycm.lua',
  main = 'ycm',
  lazy = false,
  opts = {},
}
```

## Configuration

Defaults are already the YCM defaults. Common knobs:

```lua
require('ycm').setup({
  min_num_of_chars_for_completion = 2,
  max_num_candidates = 50,
  max_num_identifier_candidates = 10,
  complete_in_comments = false,
  complete_in_strings = true,
  key_list_select_completion = { '<TAB>', '<Down>' },
  key_list_previous_completion = { '<S-TAB>', '<Up>' },
  key_list_stop_completion = { '<C-y>' },
  key_invoke_completion = '<C-Space>',
  use_lsp = true,
  lsp_merge_mode = 'exclusive',  -- or 'merge'
  lsp_snippet_expand = false,    -- expand LSP snippets via vim.snippet
  semantic_triggers = {},        -- per-filetype override, e.g. { python = { '.' } }
})
```

See `lua/ycm/options.lua` for the full list — option names mirror YCM's
`g:ycm_*` settings.

## Roadmap / known differences from classic YCM

Status: ✅ done · 🟡 partial · ❌ not implemented

**Sources**

| Feature | Status | Notes |
|---|---|---|
| Identifier completion (per-filetype, cross-buffer) | ✅ | learns identifiers as you type |
| LSP semantic completion | ✅ | trigger-based, session continuation, exclusive results |
| Auto-import (`additionalTextEdits`) | ✅ | applied on completion |
| Path completion | 🟡 | simplified; YCM handles more edge cases |
| LSP snippet expansion | 🟡 | implemented, off by default |
| UltiSnips-style snippet candidates | ❌ | |
| Identifiers from tags files | ❌ | `ycm_collect_identifiers_from_tags_files` |
| Syntax-keyword seeding | ❌ | `ycm_seed_identifiers_with_syntax` |

**Presentation**

| Feature | Status | Notes |
|---|---|---|
| `menu` / `kind` fields | ✅ | |
| Candidate documentation (`info`, preview popup) | ❌ | incl. on-demand resolve |
| Signature help | ❌ | |
| Hover popup | ❌ | |

**Beyond completion** (not planned unless requested — Neovim's built-in
diagnostics and `vim.lsp.buf.*` cover most of these)

| Feature | Status |
|---|---|
| Diagnostics UI | ❌ |
| `YcmCompleter` subcommands (GoTo / Rename / FixIt / GetDoc) | ❌ |
| Symbol finder | ❌ |

**Implementation approximations** (rarely perceptible)

| YCM | ycm.lua |
|---|---|
| ICU NFD for accent-insensitive matching | lookup table for common Latin accents |
| `re!` triggers use Python regex | Vim regex (very magic) |
| `synID` for comment/string detection | treesitter first, `synID` fallback |
| adjusts start column after auto-wrap | drops that one result (retriggers on next key) |
| LSP `textEdit` ranges | simplified to replacing the query range |

## Testing

```sh
scripts/test.sh
```

Unit tests for the matching/ranking engine plus end-to-end tests that drive a
real child Neovim instance over RPC (actual typing, actual popup menu).

## License

MIT

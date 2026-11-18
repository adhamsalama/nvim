# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a personal Neovim configuration built on **AstroNvim v6** with **Lazy.nvim** as the plugin manager. All user configuration lives in `lua/`.

## Common Commands

```bash
# Format a Lua file
stylua lua/plugins/somefile.lua

# Lint Lua files
selene lua/

# Check plugin lockfile
cat lazy-lock.json | jq '.["plugin-name"]'

# Snapshot custom LSP behavior against a JS/TS project (diff against a baseline when given)
LSP_TEST_CASES=<cases.lua> tests/lsp/run.sh <js-project> <out-dir> [<baseline-dir>]
```

## Architecture

### Entry Points

- `init.lua` — bootstraps Lazy.nvim, then calls `lua/lazy_setup.lua`
- `lua/lazy_setup.lua` — configures Lazy.nvim, sets leader keys (`<space>` and `,`), and imports from three sources:
  1. AstroNvim core
  2. `lua/community.lua` (community packs)
  3. `lua/plugins/` (all user plugin specs)

### Key Files

| File | Purpose |
|---|---|
| `lua/community.lua` | AstroNvim community packs (languages, tools, colorschemes) |
| `lua/polish.lua` | Raw Lua run after everything loads (cursor style, quickfix tweaks) |
| `lua/plugins/astrocore.lua` | Vim options, global keymaps, autocmds |
| `lua/plugins/astrolsp.lua` | LSP config (servers, format-on-save, codelens, keymaps) |
| `lua/plugins/astroui.lua` | Colorscheme and icon config |
| `lua/plugins/mason.lua` | Managed LSP/tool installs |
| `lua/plugins/lsp.lua` | Wiring (autocmds, commands, keymaps) for every custom LSP feature in `lua/lsp/` |
| `lua/plugins/lspsaga.lua` | Lspsaga, used only for its call hierarchy tree |

### Custom LSP code (`lua/lsp/`)

Logic lives in modules; `lua/plugins/lsp.lua` (and `lspsaga.lua` for the call hierarchy) only wires it up.

- `callhierarchy/` — overrides lspsaga's request function so the tree works where tsgo has no call hierarchy (functions under computed keys or in object properties, variables); `ui.lua` adds tree history (`<`/`>`, reopen-last), `dd` pruning, duplicate-entry marks (`×N` / dimmed `↑ L<n>`, `%` cycles) and the preview winbar
- `tsgo/` — shared buffer/treesitter helpers (`init.lua`), `grr`/`grR` that follow export objects (`references.lua`), Node built-in source (`builtin_source.lua`)
- `perf/` — lighter LSP on long files (`large_buf.lua` + `diag_debounce`/`inlay_range`/`words_lite`), slow-request log, statusline pending spinner
- `branch_reload.lua`, `ref_count.lua`, `functions_picker.lua`

`lua/utils/` holds only non-LSP helpers.

**Tests**: `LSP_TEST_CASES=<cases.lua> tests/lsp/run.sh <js-project> <out-dir> [<baseline-dir>]` runs the full config headless against a real JS/TS project and snapshots the LSP wiring, call hierarchy / `grr` / ref-count results and the call hierarchy UI; with a baseline dir it diffs and fails on any change. Take a baseline before a refactor, compare after. `NVIM_CONFIG_DIR=<git worktree>` runs another commit's config without touching the checkout (and without switching branches under a running editor). Runs use their own state dir and never autosave sessions. The cases file names the project's files and symbols to test with (shape: `tests/lsp/cases.example.lua`); keep it outside this repo, as it describes a private project.

### Plugin File Conventions

Each file in `lua/plugins/` returns a Lazy.nvim spec (table or array of tables). Files with `.disabled` extension are ignored by Lazy.

**Safe-disable pattern** — a file can also be suppressed with a guard at the top (no file in `lua/plugins/` uses it currently):
```lua
if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE
```
Remove that line to activate the file's plugin(s).

### Keybinding Groups

- `<leader>a` — AI (Claude Code)
- `<leader>g` — Git
- `<leader>l` — LSP
- `<leader>f` — Find (snacks picker)

### Code Style

Enforced by `.stylua.toml`: 2-space indent, 120-column width, double quotes preferred. Run `stylua` before committing Lua changes.

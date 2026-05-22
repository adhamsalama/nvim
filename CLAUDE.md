# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a personal Neovim configuration built on **AstroNvim v5+** with **Lazy.nvim** as the plugin manager. All user configuration lives in `lua/`.

## Common Commands

```bash
# Format a Lua file
stylua lua/plugins/somefile.lua

# Lint Lua files
selene lua/

# Check plugin lockfile
cat lazy-lock.json | jq '.["plugin-name"]'
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

### Plugin File Conventions

Each file in `lua/plugins/` returns a Lazy.nvim spec (table or array of tables). Files with `.disabled` extension are ignored by Lazy.

**Safe-disable pattern** — some files are active in the repo but suppressed with a guard at the top:
```lua
if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE
```
Remove that line to activate the file's plugin(s).

### Keybinding Groups

- `<leader>a` — AI (Claude Code)
- `<leader>g` — Git
- `<leader>l` — LSP
- `<leader>f` — Find/Telescope

### Code Style

Enforced by `.stylua.toml`: 2-space indent, 120-column width, double quotes preferred. Run `stylua` before committing Lua changes.

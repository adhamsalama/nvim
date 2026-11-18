-- Wiring snapshot: every autocmd, user command and keymap the config ends up with (globally, and on
-- a short and a long JS buffer once the LSP has attached), plus per-buffer LSP state and which core
-- functions are wrapped by the config. Run via tests/lsp/run.sh.

local H = dofile(debug.getinfo(1, "S").source:sub(2):match "^(.*/)" .. "helpers.lua")

local SMALL = H.cases().files.small
local LARGE = H.cases().files.large -- > 2000 lines: `lsp_lite`

local function bufname(b)
  if not b or b == 0 then return nil end
  local name = vim.api.nvim_buf_get_name(b)
  return name == "" and ("[buf %d]"):format(b) or vim.fn.fnamemodify(name, ":.")
end

-- where a function was defined: this config (path relative to it, minus the old/new module dir so
-- moves don't show up), a plugin, or Neovim's runtime
local function origin(f)
  if type(f) ~= "function" then return type(f) end
  local src = debug.getinfo(f, "S").source:gsub("^@", "")
  if H.in_config(src) then return "config" end
  if src:find "/lazy/" then return "plugin:" .. (src:match "/lazy/([^/]+)/" or "?") end
  return "runtime"
end

local function section(title, lines)
  table.sort(lines)
  H.out("## " .. title)
  local last
  for _, l in ipairs(lines) do
    if l ~= last then H.out("  " .. l) end
    last = l
  end
  H.out ""
end

local function autocmds()
  local lines = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds {}) do
    lines[#lines + 1] = table.concat({
      a.event,
      a.group_name or "-",
      a.buflocal and ("<buffer=" .. bufname(a.buffer) .. ">") or (a.pattern or "*"),
      a.desc or "",
      a.command ~= "" and a.command or (a.callback and "<cb>" or ""),
      a.once and "once" or "",
    }, " | ")
  end
  section("autocmds", lines)
end

local function commands()
  local lines = {}
  for name, c in pairs(vim.api.nvim_get_commands { builtin = false }) do
    -- script-local function references (<SNR>12_fn) carry the script's id, which follows load order
    local def = (c.definition or ""):gsub("\128\253R%d+_", "<SNR>_"):gsub("<SNR>%d+_", "<SNR>_")
    lines[#lines + 1] = ("%s nargs=%s bang=%s %s"):format(name, c.nargs, tostring(c.bang), def)
  end
  section("user commands", lines)
end

local MODES = { "n", "x", "v", "o", "i", "s", "c", "t" }
local function map_line(m)
  return table.concat({
    m.mode,
    -- canonical key names: a mapping with an alternate form (<C-J>/<NL>, <C-I>/<Tab>) is reported
    -- under either, depending on the order mappings were defined in
    vim.fn.keytrans(vim.keycode(m.lhs)),
    m.desc or "",
    m.rhs and m.rhs ~= "" and m.rhs or (m.callback and "<cb:" .. origin(m.callback) .. ">" or ""),
    m.expr == 1 and "expr" or "",
    m.nowait == 1 and "nowait" or "",
  }, " | ")
end

local function keymaps(title, bufnr)
  local lines = {}
  for _, mode in ipairs(MODES) do
    local maps = bufnr and vim.api.nvim_buf_get_keymap(bufnr, mode) or vim.api.nvim_get_keymap(mode)
    for _, m in ipairs(maps) do
      -- which-key attaches/detaches its trigger mappings on a timer: present or not depending on
      -- how fast the run got here, so not part of the config's wiring
      if not (m.desc or ""):find "^which%-key%-trigger" then lines[#lines + 1] = map_line(m) end
    end
  end
  section(title, lines)
end

local function buffer_state(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local function call(f, ...)
    local ok, v = pcall(f, ...)
    return ok and tostring(v) or "n/a"
  end
  local lines = {
    "lsp_lite=" .. tostring(vim.b[bufnr].lsp_lite),
    "snacks_words=" .. tostring(vim.b[bufnr].snacks_words),
    "foldexpr=" .. (win ~= -1 and vim.wo[win][0].foldexpr or "?"),
    "semantic_tokens=" .. call(vim.lsp.semantic_tokens.is_enabled, { bufnr = bufnr }),
    "codelens=" .. call(vim.lsp.codelens.is_enabled, { bufnr = bufnr }),
    "inlay_hints=" .. call(vim.lsp.inlay_hint.is_enabled, { bufnr = bufnr }),
    "clients=" .. table.concat(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients { bufnr = bufnr }), ","),
  }
  section("buffer state " .. bufname(bufnr), lines)
end

local function patches()
  local ch_mt = getmetatable(require "lspsaga.callhierarchy")
  local fns = {
    ["vim.lsp.util.jump_to_location"] = vim.lsp.util.jump_to_location,
    ["vim.lsp.util.open_floating_preview"] = vim.lsp.util.open_floating_preview,
    ["vim.lsp.handlers[textDocument/inlayHint]"] = vim.lsp.handlers["textDocument/inlayHint"],
    ["vim.lsp.inlay_hint.enable"] = vim.lsp.inlay_hint.enable,
    ["vim.lsp.diagnostic._refresh"] = vim.lsp.diagnostic._refresh,
    ["Client.request"] = require("vim.lsp.client").request,
    ["lspsaga.util.client_request"] = require("lspsaga.util").client_request,
    ["lspsaga.layout.left"] = require("lspsaga.layout").left,
  }
  for _, k in ipairs { "clean", "peek_view", "redraw_tree", "delete_range", "keymap", "restore_last", "history_step" } do
    fns["lspsaga.callhierarchy." .. k] = ch_mt[k]
  end
  local lines = {}
  for name, f in pairs(fns) do
    lines[#lines + 1] = name .. " = " .. origin(f)
  end
  section("wrapped functions", lines)
end

H.main(function()
  local small = H.open(SMALL)
  H.wait_client(small)
  local large = H.open(LARGE)
  H.wait_client(large)
  -- several setups are scheduled after LspAttach; let them run
  vim.wait(3000)
  -- the call hierarchy patches are installed when lspsaga loads
  require("lazy").load { plugins = { "lspsaga.nvim" } }

  commands()
  autocmds()
  keymaps "global keymaps"
  keymaps("buffer keymaps " .. SMALL, small)
  keymaps("buffer keymaps " .. LARGE, large)
  buffer_state(large) -- shown in the current window
  vim.cmd.buffer(small)
  vim.wait(500)
  buffer_state(small)
  patches()
end)

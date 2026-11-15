-- Loaded with --cmd, before the config: records, in order, every keymap / autocmd / augroup / user
-- command registration and every config module load, so a refactor can be checked for changes in
-- *order* (autocmds on one event run in creation order; mappings to one key, last one wins), not
-- just in the final state. Read back by trace.lua.

local cfg = vim.fn.stdpath "config"
local cfg_real = vim.uv.fs_realpath(cfg) or cfg
-- this harness: its own frames don't count (it may live inside the config dir or outside it)
local here = debug.getinfo(1, "S").source:gsub("^@", ""):match "^(.*/)"
local trace = {}
_G.__lsp_trace = trace

-- the first caller outside Neovim's runtime and this file: config, plugin:<name> or runtime
local function origin()
  for level = 3, 40 do
    local info = debug.getinfo(level, "S")
    if not info then break end
    local src = info.source:gsub("^@", "")
    if not (src:find("/share/nvim/runtime/", 1, true) or vim.startswith(src, here) or src:sub(1, 1) ~= "/") then
      if vim.startswith(src, cfg .. "/") or vim.startswith(src, cfg_real .. "/") then return "config" end
      return "plugin:" .. (src:match "/lazy/([^/]+)/" or src)
    end
  end
  return "runtime"
end

local function bufname(b)
  if b == nil then return nil end
  if b == 0 then b = vim.api.nvim_get_current_buf() end
  local ok, name = pcall(vim.api.nvim_buf_get_name, b)
  if not ok then return "?" end
  return name == "" and "[no name]" or vim.fn.fnamemodify(name, ":.")
end

local function key(lhs)
  local ok, k = pcall(function() return vim.fn.keytrans(vim.keycode(lhs)) end)
  return ok and k or lhs
end

local function add(...) trace[#trace + 1] = table.concat(vim.tbl_map(tostring, { ... }), " | ") end

local api = vim.api
local function wrap(name, fmt)
  local orig = api[name]
  api[name] = function(...)
    local ok, line = pcall(fmt, ...)
    if ok and line then add(name, line, origin()) end
    return orig(...)
  end
end

local function events(e) return type(e) == "table" and table.concat(e, ",") or tostring(e) end
local function group(g)
  if type(g) == "number" then
    local ok, ac = pcall(api.nvim_get_autocmds, { group = g })
    return ok and ac[1] and ac[1].group_name or ("#" .. g)
  end
  return tostring(g)
end

wrap("nvim_set_keymap", function(mode, lhs, rhs, o)
  o = o or {}
  if (o.desc or ""):find "^which%-key%-trigger" then return end
  return ("%s %s %s %s"):format(mode, key(lhs), o.desc or "", rhs ~= "" and rhs or "<cb>")
end)
wrap("nvim_buf_set_keymap", function(buf, mode, lhs, rhs, o)
  o = o or {}
  if (o.desc or ""):find "^which%-key%-trigger" then return end
  return ("<%s> %s %s %s %s"):format(bufname(buf), mode, key(lhs), o.desc or "", rhs ~= "" and rhs or "<cb>")
end)
wrap("nvim_del_keymap", function(mode, lhs) return ("%s %s"):format(mode, key(lhs)) end)
wrap("nvim_buf_del_keymap", function(buf, mode, lhs) return ("<%s> %s %s"):format(bufname(buf), mode, key(lhs)) end)
wrap("nvim_create_augroup", function(name, o) return ("%s clear=%s"):format(name, tostring((o or {}).clear)) end)
wrap("nvim_del_augroup_by_name", function(name) return name end)
wrap("nvim_create_autocmd", function(ev, o)
  o = o or {}
  return ("%s group=%s pattern=%s buf=%s desc=%s"):format(
    events(ev),
    group(o.group),
    events(o.pattern),
    tostring(o.buffer and bufname(o.buffer)),
    o.desc or ""
  )
end)
-- namespace ids follow creation order (and decorations of equal priority are ordered by them)
wrap("nvim_create_namespace", function(name) return name end)
wrap("nvim_create_user_command", function(name, _, o) return ("%s desc=%s"):format(name, (o or {}).desc or "") end)
wrap(
  "nvim_buf_create_user_command",
  function(buf, name, _, o) return ("<%s> %s desc=%s"):format(bufname(buf), name, (o or {}).desc or "") end
)

-- config modules, by their current name; the refactor renamed these, so map old names onto new
local renamed = {
  ["utils.lsp_branch_reload"] = "lsp.branch_reload",
  ["utils.ref_count"] = "lsp.ref_count",
  ["utils.tsgo"] = "lsp.tsgo",
  ["utils.lsp_diag_debounce"] = "lsp.perf.diag_debounce",
  ["utils.lsp_inlay_range"] = "lsp.perf.inlay_range",
  ["utils.lsp_pending"] = "lsp.perf.pending",
  ["utils.lsp_slow"] = "lsp.perf.slow",
  ["utils.lsp_words_lite"] = "lsp.perf.words_lite",
}
local orig_require = require
_G.require = function(name)
  if
    package.loaded[name] == nil
    and type(name) == "string"
    and (name:match "^utils%." or name:match "^lsp%." or name == "lsp")
  then
    add("require", renamed[name] or name)
  end
  return orig_require(name)
end

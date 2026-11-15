-- Shared helpers for the headless LSP snapshot scripts in this directory (see tests/lsp/run.sh).
-- They run inside the full config, with the cwd set to the project under test.

local M = {}

M.cfg = vim.fn.stdpath "config"
local cfg_real = vim.uv.fs_realpath(M.cfg) or M.cfg

-- is `path` inside the config dir (which may be reached through a symlink, see run.sh)?
function M.in_config(path) return vim.startswith(path, M.cfg .. "/") or vim.startswith(path, cfg_real .. "/") end
M.lines = {}

function M.out(s) M.lines[#M.lines + 1] = s end

-- The project-specific targets (which files to open, where to put the cursor) come from a Lua file
-- named by $LSP_TEST_CASES, kept outside this repo; see cases.example.lua for its shape.
local cases
function M.cases()
  if not cases then
    local path = assert(os.getenv "LSP_TEST_CASES", "LSP_TEST_CASES not set (see tests/lsp/cases.example.lua)")
    cases = dofile(vim.fn.expand(path))
  end
  return cases
end

-- position of a `{ line = ..., token = ... }` target in `bufnr`
function M.target(bufnr, name)
  local t = assert(M.cases().targets[name], "target missing from LSP_TEST_CASES: " .. name)
  return M.find(bufnr, t.line, t.token, t.nth)
end

function M.log(...)
  local parts = vim.tbl_map(tostring, { ... })
  io.stderr:write(table.concat(parts, " ") .. "\n")
end

-- AstroNvim saves "Last Session" and the cwd's dirsession on VimLeavePre; a test run must not
-- overwrite the user's sessions
local function quit(cmd)
  pcall(vim.api.nvim_del_augroup_by_name, "resession_auto_save")
  vim.cmd(cmd)
end

-- write the collected lines to $SNAPSHOT_OUT and quit
function M.finish()
  local path = assert(os.getenv "SNAPSHOT_OUT", "SNAPSHOT_OUT not set")
  local f = assert(io.open(path, "w"))
  f:write(table.concat(M.lines, "\n") .. "\n")
  f:close()
  quit "qa!"
end

-- run `fn` and quit with an error code if it throws, so a broken run never leaves nvim hanging
-- Must run after VimEnter (run.sh starts the scripts from a VimEnter autocmd). Headless nvim has no
-- UIEnter, so lazy.nvim never fires `VeryLazy` (nor anything else on UIEnter): fire it, so the plugin
-- set matches an interactive session. `fn` runs in a coroutine so it can `M.yield()` back to the
-- main loop, which is where events like WinScrolled are fired.
function M.main(fn)
  local co = coroutine.create(function()
    local ok, err = xpcall(function()
      if not vim.g.did_very_lazy then vim.api.nvim_exec_autocmds("UIEnter", { modeline = false }) end
      M.wait(30000, function() return vim.g.did_very_lazy == true end, "VeryLazy")
      fn()
    end, debug.traceback)
    if not ok then
      M.log("SNAPSHOT FAILED: " .. tostring(err))
      quit "cquit 1"
    end
    M.finish()
  end)
  local ok, err = coroutine.resume(co)
  if not ok then
    M.log("SNAPSHOT FAILED: " .. tostring(err))
    quit "cquit 1"
  end
end

-- let the main loop run for `ms` (unlike vim.wait, which only processes events, this lets Neovim
-- fire the events it checks for between commands: WinScrolled, CursorMoved, ...)
function M.yield(ms)
  local co = assert(coroutine.running(), "M.yield outside M.main")
  vim.defer_fn(function() assert(coroutine.resume(co)) end, ms or 0)
  coroutine.yield()
end

function M.rel(uri)
  if not uri then return nil end
  return vim.fn.fnamemodify(vim.uri_to_fname(uri), ":.")
end

function M.open(file)
  vim.cmd.edit(vim.fn.fnameescape(file))
  return vim.api.nvim_get_current_buf()
end

function M.wait_client(bufnr, name)
  local client
  local ok = vim.wait(120000, function()
    client = vim.lsp.get_clients({ bufnr = bufnr, name = name or "tsc" })[1]
    return client ~= nil and client.initialized == true
  end, 50)
  assert(ok, "LSP client did not attach to " .. vim.api.nvim_buf_get_name(bufnr))
  return client
end

-- 0-based LSP position of the `nth` occurrence of `token` on the first line containing `line_pat`
-- (both plain strings), so cases survive unrelated edits to the project.
function M.find(bufnr, line_pat, token, nth)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(line_pat, 1, true) then
      local col = 0
      for _ = 1, nth or 1 do
        col = assert(l:find(token, col + 1, true), ("token %q not on line %d"):format(token, i))
      end
      return { line = i - 1, character = col - 1 }
    end
  end
  error(("line %q not found"):format(line_pat))
end

-- vim.wait until `pred` holds; errors on timeout
function M.wait(ms, pred, what) assert(vim.wait(ms, pred, 20), "timeout waiting for " .. what) end

-- Deterministic one-line rendering of a value: tables with sorted keys, lists in order.
function M.enc(v)
  local t = type(v)
  if t == "table" then
    if vim.islist(v) then
      local parts = {}
      for _, x in ipairs(v) do
        parts[#parts + 1] = M.enc(x)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = vim.tbl_keys(v)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = tostring(k) .. "=" .. M.enc(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return ("%q"):format(v)
  elseif t == "function" then
    return "<fn>"
  end
  return tostring(v)
end

return M

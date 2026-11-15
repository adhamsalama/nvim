-- Runtime snapshot: exercises every custom LSP feature through its real entry point (the keymap's
-- or command's callback, or the editor event that drives it) rather than calling the module:
--   grr / grR / <Leader>lN / <Leader>lF / <Leader>lt and their commands, the slow-request log and
--   statusline spinner, long-file inlay hints / document highlight / diagnostic debounce, and the
--   LSP restart on a git branch switch. Run via tests/lsp/run.sh.

local H = dofile(debug.getinfo(1, "S").source:sub(2):match "^(.*/)" .. "helpers.lua")

local SMALL = H.cases().files.small
local LARGE = H.cases().files.large -- > 2000 lines: `lsp_lite`

local function require_any(...)
  for _, name in ipairs { ... } do
    local ok, mod = pcall(require, name)
    if ok then return mod end
  end
  error("none of these modules found: " .. table.concat({ ... }, ", "))
end

-- capture notifications while `fn` runs (and `wait_for` holds), passing them through
local function with_notify(fn, wait_for, ms)
  local got = {}
  local orig = vim.notify
  vim.notify = function(msg, ...)
    got[#got + 1] = tostring(msg)
    return orig(msg, ...)
  end
  local ok, err = pcall(function()
    fn()
    if wait_for then H.wait(ms or 60000, function() return wait_for(got) end, "notification") end
  end)
  vim.notify = orig
  if not ok then error(err, 0) end
  return got
end

local function map_cb(lhs, buf)
  local m = vim.fn.maparg(lhs, "n", false, true)
  assert(m.callback or m.rhs, "no mapping for " .. lhs)
  if buf then assert(m.buffer == 1, lhs .. " is not buffer-local") end
  return m
end

local function run_map(lhs, buf)
  local m = map_cb(lhs, buf)
  if m.callback then
    m.callback()
  else
    vim.api.nvim_feedkeys(vim.keycode(m.rhs), "x", false)
  end
end

local function cursor_on(bufnr, target)
  local p = H.target(bufnr, target)
  vim.api.nvim_win_set_cursor(0, { p.line + 1, p.character })
  return p
end

local function qf_dump(title)
  local qf = vim.fn.getqflist { title = 1, items = 1 }
  H.out("## " .. title)
  H.out("  title: " .. qf.title)
  local items = {}
  for _, it in ipairs(qf.items) do
    items[#items + 1] = ("%s:%d:%d"):format(vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ":."), it.lnum, it.col)
  end
  table.sort(items)
  for _, l in ipairs(items) do
    H.out("  " .. l)
  end
  H.out ""
end

local function references(lhs, title)
  vim.fn.setqflist({}, " ", { title = "__pending__" })
  run_map(lhs, true)
  H.wait(120000, function() return vim.fn.getqflist({ title = 1 }).title ~= "__pending__" end, lhs)
  vim.cmd "cclose"
  qf_dump(title)
end

local function keymaps(small)
  -- grr/grR are set on a scheduled callback after LspAttach
  H.wait(
    10000,
    function() return (vim.fn.maparg("grr", "n", false, true).desc or ""):find "^References %(scoped" ~= nil end,
    "tsgo grr mapping"
  )
  cursor_on(small, "use_in_function")
  references("grr", "grr on a use (keymap)")
  references("grR", "grR on a use (keymap)")

  -- <Leader>lN: open the Node source of the built-in under the cursor
  cursor_on(small, "node_builtin")
  local opened
  local orig_open = vim.ui.open
  vim.ui.open = function(url) opened = url end
  local notes = with_notify(function() run_map("<Leader>lN", true) end, function() return opened ~= nil end)
  vim.ui.open = orig_open
  H.out "## <Leader>lN"
  H.out("  opened: " .. tostring(opened))
  for _, n in ipairs(notes) do
    H.out("  notify: " .. n)
  end
  H.out ""

  -- <Leader>lF / :BufferFunctions / :WorkspaceFunctions: the snacks picker options
  local snacks = require "snacks"
  local calls = {}
  local orig_sym, orig_ws = snacks.picker.lsp_symbols, snacks.picker.lsp_workspace_symbols
  local samples = { { name = "foo" }, { name = "" }, { name = "anonymous" }, { name = "describe() callback" } }
  local function capture(kind)
    return function(opts)
      local verdicts = {}
      for _, s in ipairs(samples) do
        local v = opts.transform(s)
        verdicts[#verdicts + 1] = ("%q=%s"):format(s.name, tostring(v))
      end
      local o = vim.deepcopy(opts)
      o.transform = nil
      calls[#calls + 1] = kind .. " " .. H.enc(o) .. " transform: " .. table.concat(verdicts, " ")
    end
  end
  snacks.picker.lsp_symbols, snacks.picker.lsp_workspace_symbols =
    capture "lsp_symbols", capture "lsp_workspace_symbols"
  run_map "<Leader>lF"
  vim.cmd "BufferFunctions"
  vim.cmd "WorkspaceFunctions"
  snacks.picker.lsp_symbols, snacks.picker.lsp_workspace_symbols = orig_sym, orig_ws
  H.out "## <Leader>lF, :BufferFunctions, :WorkspaceFunctions"
  for _, c in ipairs(calls) do
    H.out("  " .. c)
  end
  H.out ""

  -- <Leader>lt / :RefCountRefresh / :RefCountDebug
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ns = vim.api.nvim_create_namespace "lsp_ref_count"
  local function marks() return #vim.api.nvim_buf_get_extmarks(small, ns, 0, -1, {}) end
  H.out "## <Leader>lt and ref count commands"
  local n1 = with_notify(function() run_map "<Leader>lt" end)
  H.wait(120000, function() return marks() > 0 end, "ref counts")
  H.out("  toggle on: " .. table.concat(n1, " / ") .. ", marks>0")
  vim.cmd "RefCountRefresh"
  H.wait(120000, function() return marks() > 0 end, "ref counts after refresh")
  H.out "  :RefCountRefresh: marks>0"
  local dbg = with_notify(function() vim.cmd "RefCountDebug" end)
  for _, d in ipairs(dbg) do
    for l in vim.gsplit(d, "\n") do
      -- in-flight count depends on timing
      if not l:find "in%-flight" then H.out("  debug| " .. l) end
    end
  end
  local n2 = with_notify(function() run_map "<Leader>lt" end)
  H.out("  toggle off: " .. table.concat(n2, " / ") .. ", marks=" .. marks())
  H.out ""
end

local function slow_and_pending(small)
  local slow = require_any("lsp.perf.slow", "utils.lsp_slow")
  local pending = require_any("lsp.perf.pending", "utils.lsp_pending")
  local client = H.wait_client(small)
  local orig_threshold = slow.threshold_ms
  slow.threshold_ms = 1
  vim.wait(1000) -- let earlier requests settle
  os.remove(slow.log_path)

  local seen_pending, done = false, false
  local p = H.target(small, "node_builtin")
  client:request("textDocument/hover", {
    textDocument = { uri = vim.uri_from_bufnr(small) },
    position = p,
  }, function() done = true end, small)
  H.wait(60000, function()
    if pending.pending(small) ~= nil then seen_pending = true end
    return done
  end, "hover")
  vim.wait(500)
  slow.threshold_ms = orig_threshold
  H.out "## slow-request log and pending spinner (threshold lowered to 1ms)"
  H.out("  spinner shown while pending: " .. tostring(seen_pending))
  H.out("  spinner cleared after reply: " .. tostring(pending.pending(small) == nil))
  local f = io.open(slow.log_path)
  local hover_logged = false
  for l in (f and f:read "*a" or ""):gmatch "[^\n]+" do
    if l:find "hover" and l:find(SMALL, 1, true) then hover_logged = true end
  end
  if f then f:close() end
  H.out("  hover logged with file: " .. tostring(hover_logged))
  vim.cmd "LspSlow"
  H.out("  :LspSlow opens: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
  vim.cmd "close"
  local n = with_notify(function() vim.cmd "LspSlow!" end)
  H.out("  :LspSlow!: " .. table.concat(n, " / ") .. ", log exists=" .. tostring(vim.uv.fs_stat(slow.log_path) ~= nil))
  H.out ""
  vim.cmd.buffer(small)
end

local function rows(bufnr, ns, first, last)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, { first, 0 }, { last, -1 }, {})) do
    out[#out + 1] = m[2]
  end
  return out
end

local function large_file()
  local large = H.open(LARGE)
  H.wait_client(large)
  local lines = vim.api.nvim_buf_line_count(large)
  H.out "## long file"
  H.out("  lsp_lite=" .. tostring(vim.b[large].lsp_lite))

  -- inlay hints: only around what is visible, following scrolls. Headless nvim only computes the
  -- visible range (and fires WinScrolled) on redraw, which a UI does continuously.
  local ns = vim.api.nvim_create_namespace "lsp_inlay_range"
  local done = 0
  local id = vim.api.nvim_create_autocmd("LspRequest", {
    buffer = large,
    callback = function(args)
      local r = args.data.request
      if r.method == "textDocument/inlayHint" and r.type == "complete" then done = done + 1 end
    end,
  })
  local function round(what)
    local before = done
    for _ = 1, 1200 do
      if done > before then break end
      vim.cmd.redraw()
      H.yield(100)
    end
    assert(done > before, "timeout waiting for " .. what)
    H.yield(500)
  end
  round "inlay hints at top"
  local top = #rows(large, ns, 0, -1)
  vim.api.nvim_win_set_cursor(0, { 4000, 0 })
  vim.cmd "normal! zt"
  round "inlay hints after scroll"
  vim.api.nvim_del_autocmd(id)
  local near, all = #rows(large, ns, 3900, 4200), #rows(large, ns, 0, -1)
  H.out(
    ("  inlay hints: %d near the top; after scrolling to line 4000: %d near it, %d elsewhere (of %d lines)"):format(
      top,
      near,
      all - near - top,
      lines
    )
  )

  -- document highlight via words_lite (snacks.words is off on long files)
  local p = H.target(large, "large_identifier")
  vim.api.nvim_win_set_cursor(0, { p.line + 1, p.character })
  vim.cmd "normal! zz"
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = large })
  local wns = vim.api.nvim_get_namespaces()
  local hl
  H.wait(30000, function()
    for name, id in pairs(wns) do
      if name:find "references" then
        local r = rows(large, id, 0, -1)
        if #r > 0 then
          hl = r
          return true
        end
      end
    end
  end, "document highlight")
  H.out(("  document highlight rows: %d, first %d"):format(#hl, hl[1]))

  -- diagnostic pulls after an edit: debounced (1.5s on long files), one request. The server may
  -- also ask for a re-pull (workspace/diagnostic/refresh, e.g. when files change on disk), which
  -- adds a pull that isn't the edit's: measure again when that happens.
  local function measure()
    vim.wait(3000)
    local pulls, refreshes = 0, 0
    local id = vim.api.nvim_create_autocmd("LspRequest", {
      buffer = large,
      callback = function(args)
        if args.data.request.type == "pending" and args.data.request.method == "textDocument/diagnostic" then
          pulls = pulls + 1
        end
      end,
    })
    local orig_refresh = vim.lsp.handlers["workspace/diagnostic/refresh"]
    vim.lsp.handlers["workspace/diagnostic/refresh"] = function(...)
      refreshes = refreshes + 1
      return orig_refresh(...)
    end
    vim.api.nvim_buf_set_lines(large, 0, 0, false, { "// edit" })
    vim.wait(1000)
    local early = pulls
    vim.wait(2500)
    vim.api.nvim_del_autocmd(id)
    vim.lsp.handlers["workspace/diagnostic/refresh"] = orig_refresh
    return early, pulls, refreshes
  end
  local early, pulls, refreshes
  for _ = 1, 3 do
    early, pulls, refreshes = measure()
    if refreshes == 0 then break end
  end
  assert(refreshes == 0, "server kept requesting diagnostic refreshes")
  H.out(("  diagnostic pulls after an edit: %d within 1s, %d within 3.5s"):format(early, pulls))
  H.out ""
end

local function branch_reload(dir)
  vim.fn.mkdir(dir, "p")
  local function git(...)
    local r = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
    assert(r.code == 0, table.concat({ ... }, " ") .. ": " .. (r.stderr or ""))
  end
  git("init", "-q", "-b", "main")
  git("config", "user.email", "test@example.invalid")
  git("config", "user.name", "test")
  vim.fn.writefile({ '{ "name": "branch-reload-test" }' }, dir .. "/package.json")
  vim.fn.writefile({ "export const a = 1;" }, dir .. "/a.js")
  git("add", ".")
  git("commit", "-q", "-m", "one")
  git("switch", "-q", "-c", "other")
  vim.fn.writefile({ "export const a = 2;" }, dir .. "/a.js")
  git("commit", "-q", "-am", "two")
  git("switch", "-q", "main")

  local buf = H.open(dir .. "/a.js")
  local first = H.wait_client(buf)
  vim.wait(2000) -- watcher starts on LspAttach
  git("switch", "-q", "other")
  local now
  local ok = vim.wait(30000, function()
    now = vim.lsp.get_clients({ bufnr = buf, name = "tsc" })[1]
    return now ~= nil and now.id ~= first.id and now.initialized == true
  end, 100)
  H.out "## branch switch"
  H.out("  tsc restarted: " .. tostring(ok))
  H.out("  buffer reloaded from disk: " .. vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  H.out ""
end

H.main(function()
  local small = H.open(SMALL)
  H.wait_client(small)
  keymaps(small)
  slow_and_pending(small)
  large_file()
  branch_reload(assert(os.getenv "SNAPSHOT_TMP", "SNAPSHOT_TMP not set") .. "/branch-repo")
end)

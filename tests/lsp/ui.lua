-- UI snapshot: drive the real lspsaga call hierarchy window headless and record the tree text after
-- each step (open, expand, `dd`, quit, restore_last) with its duplicate-entry marks, plus the preview
-- window's winbar. Covers the additions in lua/lsp/callhierarchy/ui.lua. Run via tests/lsp/run.sh.

local H = dofile(debug.getinfo(1, "S").source:sub(2):match "^(.*/)" .. "helpers.lua")

local FILE = H.cases().files.small

local function tree_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "sagacallhierarchy" then return w end
  end
end

-- tree text, each line followed by its duplicate-entry marks (eol virt_text, `[dim]` when dimmed)
local function tree_lines()
  local w = tree_win()
  if not w then return nil end
  local buf = vim.api.nvim_win_get_buf(w)
  local ns = vim.api.nvim_get_namespaces().SagaCallhierarchyDup
  local lines = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    l = l:gsub("%s+$", "")
    local marks = ns and vim.api.nvim_buf_get_extmarks(buf, ns, { i - 1, 0 }, { i - 1, -1 }, { details = true })
    for _, m in ipairs(marks or {}) do
      l = l .. (m[4].virt_text and m[4].virt_text[1][1] or "") .. (m[4].hl_group and " [dim]" or "")
    end
    lines[i] = l
  end
  return lines
end

local function snap(title)
  H.out("## " .. title)
  local lines = tree_lines()
  if not lines then
    H.out "  (no tree window)"
  else
    for _, l in ipairs(lines) do
      H.out("  |" .. l)
    end
  end
  H.out ""
end

-- wait until the tree has `n` lines and stops changing
local function settle(n)
  local prev, stable = nil, 0
  local ok = vim.wait(60000, function()
    local lines = tree_lines()
    local cur = lines and table.concat(lines, "\n")
    stable = (cur ~= nil and cur == prev and #lines >= n) and stable + 1 or 0
    prev = cur
    return stable >= 10
  end, 20)
  if not ok then error("tree did not settle at " .. n .. " lines: " .. vim.inspect(tree_lines())) end
end

local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false) end

H.main(function()
  local bufnr = H.open(FILE)
  H.wait_client(bufnr)
  local p = H.target(bufnr, "call_hierarchy_root")
  vim.api.nvim_win_set_cursor(0, { p.line + 1, p.character })

  vim.cmd "Lspsaga incoming_calls"
  H.wait(60000, function() return tree_win() ~= nil end, "tree window")
  settle(1)
  snap "open"

  vim.api.nvim_set_current_win(tree_win())
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  press "<Tab>"
  settle(2)
  snap "expand line 1"

  -- preview window: heirline winbar is set after the cursor moves in the tree
  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
  vim.wait(200)
  -- lspsaga's own preview window (other floats, like a notification, may be open meanwhile)
  local preview = require("lspsaga.callhierarchy").right_winid
  H.out "## preview winbar"
  H.out("  " .. (preview and vim.api.nvim_win_is_valid(preview) and vim.wo[preview].winbar or "(no preview window)"))
  H.out ""

  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  press "dd"
  vim.wait(200)
  snap "dd on line 2"

  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  press "dd"
  vim.wait(200)
  snap "dd on line 1 (the first node anchors the list)"

  press "q"
  H.wait(5000, function() return tree_win() == nil end, "tree to close")
  snap "after q"

  require("lspsaga.callhierarchy"):restore_last()
  H.wait(5000, function() return tree_win() ~= nil end, "restored tree")
  vim.wait(200)
  snap "restore_last"
  local cfg = vim.api.nvim_win_get_config(tree_win())
  H.out(
    ("## restored tree height >= 85%% of lines: %s"):format(tostring(cfg.height >= math.floor(vim.o.lines * 0.85) - 4))
  )
end)

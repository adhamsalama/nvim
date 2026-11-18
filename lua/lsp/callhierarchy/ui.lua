-- Call hierarchy tree UI additions on top of lspsaga (installed by lua/plugins/lspsaga.lua).

local M = {}

function M.setup()
  -- Call hierarchy history: reopen the last tree, or step through earlier ones, expansions included.
  --
  -- Every way out of the tree (quit, close, and the edit/split/tabe jumps) goes through
  -- `ch:clean()`, which nils every field on the instance. The tree itself is the `self.list`
  -- linked list: each node keeps its `inlevel`, `expand` state and `winline` (-1 when hidden
  -- under a collapsed parent), so holding on to it is enough to redraw the same view. The
  -- hook goes on the metatable because `clean()` would wipe anything set on the instance.
  --
  -- Every tree shown is kept in a history (like the quickfix stack, newest last, capped at
  -- HISTORY_MAX); `<`/`>` in the tree step to the older/newer one and `<Leader>lv` reopens the one
  -- viewed last. An entry is the same `self.list` table the tree mutates, so expansions and `dd`
  -- pruning carry over, plus the cursor row.
  local ch = require "lspsaga.callhierarchy"
  local mt = getmetatable(ch)
  local saga_config = require("lspsaga").config
  local HISTORY_MAX = 10
  local history, history_pos = {}, 0 -- history_pos: index of the tree shown / viewed last

  -- The history entry for `self.list`, added as the newest one if it isn't there yet. Makes it current.
  local function track(self)
    for i, e in ipairs(history) do
      if e.list == self.list then
        e.method, e.layout, e.main_buf = self.method, self.layout, self.main_buf
        history_pos = i
        return e
      end
    end
    table.insert(history, { list = self.list, method = self.method, layout = self.layout, main_buf = self.main_buf })
    if #history > HISTORY_MAX then table.remove(history, 1) end
    history_pos = #history
    return history[history_pos]
  end

  -- peek_view marks every buffer that wasn't *loaded* when previewed as `wipe`, and clean() wipes it,
  -- even when the buffer already existed unloaded and something holds its number: quickfix entries
  -- (e.g. from `<C-q>` below), the jumplist, marks. Wiping it leaves those pointing at nothing (qf
  -- lines lose their filename and :cnext stops there). Unload instead: memory and the LSP attachment
  -- are released the same, but the buffer number and name survive.
  local orig_clean = mt.clean
  mt.clean = function(self)
    local unload = {}
    if self.list and self.list.value then
      track(self)
      require("lspsaga.slist").list_map(self.list, function(node)
        local v = node.value
        if v and v.wipe then
          v.wipe = nil
          unload[v.bufnr] = true
        end
      end)
    end
    orig_clean(self) -- closes the tree + preview windows first
    for bufnr in pairs(unload) do
      if vim.api.nvim_buf_is_loaded(bufnr) and not vim.bo[bufnr].modified and #vim.fn.win_findbuf(bufnr) == 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { unload = true })
      end
    end
  end

  -- Show our heirline winbar (path + file + symbol breadcrumbs) on the preview window.
  -- Heirline skips it on its own: preview buffers come from `bufload()`, so they're unlisted and
  -- AstroNvim's `disable_winbar_cb` rejects them, clearing the winbar on every `BufWinEnter`.
  -- peek_view swaps the previewed buffer on CursorMoved in the tree, so set it again after each swap;
  -- this autocmd is created after lspsaga's, so it runs after the swap.
  local heirline_winbar = "%{%v:lua.require'heirline'.eval_winbar()%}"
  local orig_peek_view = mt.peek_view
  mt.peek_view = function(self)
    orig_peek_view(self)
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = vim.api.nvim_create_augroup("SagaCallhierarchyWinbar", { clear = true }),
      buffer = self.left_bufnr,
      callback = function()
        if self.right_winid and vim.api.nvim_win_is_valid(self.right_winid) then
          vim.api.nvim_set_option_value("winbar", heirline_winbar, { scope = "local", win = self.right_winid })
          -- the file_info component is cached until `BufEnter`, which swapping the preview buffer
          -- doesn't fire; run heirline's own invalidation handlers so it shows the new file
          vim.api.nvim_exec_autocmds("BufEnter", { group = "Heirline_update_autocmds" })
        end
      end,
    })
  end

  -- Repaint the whole left buffer from the (possibly mutated) slist: one line per visible node
  -- (`winline > 0`), with its toggle icon, kind icon and tree connectors. Clearing the namespace
  -- first drops stale extmarks, so this is safe to call on an existing buffer after an edit.
  -- Assumes visible winlines are a contiguous 1..N (see `renumber` in `delete_node`).
  mt.redraw_tree = function(self)
    local incoming = self.method == "callHierarchy/incomingCalls"
    local visible, lines = {}, {}
    require("lspsaga.slist").list_map(self.list, function(node)
      local v = node.value
      if v and v.winline and v.winline > 0 then
        visible[#visible + 1] = v
        lines[v.winline] = (" "):rep(v.inlevel) .. (incoming and v.from or v.to).name
      end
    end)
    local ns = vim.api.nvim_create_namespace "SagaCallhierarchy"
    vim.bo[self.left_bufnr].modifiable = true
    vim.api.nvim_buf_clear_namespace(self.left_bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_lines(self.left_bufnr, 0, -1, false, lines)
    local kind = require("lspsaga.lspkind").kind
    for _, v in ipairs(visible) do
      local row = v.winline - 1
      self:set_toggle_icon(v.expand and saga_config.ui.collapse or saga_config.ui.expand, row, v.inlevel - 4, v.virtid)
      local k = kind[(incoming and v.from or v.to).kind]
      vim.api.nvim_buf_set_extmark(self.left_bufnr, ns, row, v.inlevel - 2, {
        virt_text = { { k[2], "Saga" .. k[3] } },
        virt_text_pos = "overlay",
      })
      self:render_virtline(row, v.inlevel)
    end
    vim.bo[self.left_bufnr].modifiable = false
  end

  -- Drop every node whose line falls in `[lstart, lend]`, each together with its whole subtree.
  -- The slist is pre-order, so a node's descendants are the following entries with a deeper
  -- `inlevel`: walk once, keeping survivors and skipping any node selected in the range plus
  -- everything under it (`level` holds the inlevel we're pruning beneath). Renumber the remaining
  -- visible lines to a contiguous 1..N and repaint. The root (the symbol the hierarchy was opened
  -- on) is never removed — it anchors the list.
  mt.delete_range = function(self, lstart, lend)
    if not (self.left_winid and vim.api.nvim_win_is_valid(self.left_winid)) then return end
    local slist = require "lspsaga.slist"
    local survivors, removed, level = {}, 0, nil
    slist.list_map(self.list, function(node)
      local v = node.value
      if level and v.inlevel > level then
        removed = removed + 1 -- a descendant of a node already removed
        return
      end
      level = nil
      if node ~= self.list and v.winline and v.winline > 0 and v.winline >= lstart and v.winline <= lend then
        level = v.inlevel -- remove this node and, below, its subtree
        removed = removed + 1
        return
      end
      survivors[#survivors + 1] = node
    end)
    if removed == 0 then
      if lstart <= 1 and lend >= 1 then
        vim.notify("[lspsaga] can't delete the root of the call hierarchy", vim.log.levels.WARN)
      end
      return
    end
    local count = 0
    for i, node in ipairs(survivors) do
      node.next = survivors[i + 1]
      if node.value.winline and node.value.winline > 0 then
        count = count + 1
        node.value.winline = count
      end
    end
    self:redraw_tree()
    local row = math.max(1, math.min(lstart, vim.api.nvim_buf_line_count(self.left_bufnr)))
    vim.api.nvim_win_set_cursor(self.left_winid, { row, 4 })
  end

  -- Send the visible tree (pre-order, so tree order is kept; pruned and collapsed entries are left
  -- out) to the quickfix list, indented by depth. Incoming entries point at the call site inside
  -- the caller; outgoing entries at the callee's definition (their fromRanges are in the parent).
  mt.to_qflist = function(self)
    local incoming = self.method == "callHierarchy/incomingCalls"
    local items, min_level = {}, math.huge
    require("lspsaga.slist").list_map(self.list, function(node)
      local v = node.value
      if not (v and v.winline and v.winline > 0) then return end
      local data = incoming and v.from or v.to
      local range = incoming and v.fromRanges and v.fromRanges[1] or data.selectionRange or data.range
      local client = vim.lsp.get_client_by_id(v.client_id)
      local item = vim.lsp.util.locations_to_items(
        { { uri = data.uri, range = range } },
        client and client.offset_encoding or "utf-16"
      )[1]
      if item then
        item.level, item.name = v.inlevel, data.name
        min_level = math.min(min_level, v.inlevel)
        items[#items + 1] = item
      end
    end)
    if #items == 0 then return vim.notify("[lspsaga] call hierarchy is empty", vim.log.levels.WARN) end
    for _, item in ipairs(items) do
      item.text = ("  "):rep((item.level - min_level) / 2) .. item.name
      item.level, item.name = nil, nil
    end
    local title = (incoming and "Incoming calls: " or "Outgoing calls: ") .. vim.trim(items[1].text)
    require("lspsaga.util").close_win { self.left_winid, self.right_winid }
    self:clean()
    vim.fn.setqflist({}, " ", { title = title, items = items })
    vim.cmd "botright copen"
  end

  -- Duplicate entries: the same function (same uri + selectionRange start) shown on more than one
  -- visible line. The first occurrence gets a `×N` count, every later one is dimmed with `↑ L<n>`
  -- pointing at the first; with the cursor on any occurrence, all of them are highlighted, and `%`
  -- cycles through them. Marks live in their own namespace, so lspsaga's extmark edits leave them be.
  local function set_dup_hls()
    vim.api.nvim_set_hl(0, "SagaCallhierarchyDup", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "SagaCallhierarchyDupRef", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "SagaCallhierarchyDupCount", { link = "DiagnosticInfo", default = true })
    vim.api.nvim_set_hl(0, "SagaCallhierarchyDupCursor", { link = "LspReferenceText", default = true })
  end
  set_dup_hls()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("SagaCallhierarchyDupHl", { clear = true }),
    callback = set_dup_hls,
  })

  -- Identity of the function an entry stands for. Incoming entries have `selectionRange` rewritten
  -- to the call site (see lsp/callhierarchy/init.lua), so prefer the declaration: `__ref_pos` (name of
  -- the enclosing function, on reference-driven entries), then `__decl_range` (the original selectionRange).
  local function item_key(item)
    local pos = item.__ref_pos or ((item.__decl_range or item.selectionRange or item.range or {}).start or {})
    return ("%s:%d:%d"):format(item.uri, pos.line or -1, pos.character or -1)
  end

  -- Recompute the marks from the visible nodes; `self.dup_rows[winline]` holds the sorted winlines
  -- of that line's duplicate group (only set for lines that have duplicates).
  mt.mark_duplicates = function(self)
    local buf = self.left_bufnr
    if not (buf and vim.api.nvim_buf_is_valid(buf) and self.list and self.list.value) then return end
    local incoming = self.method == "callHierarchy/incomingCalls"
    local groups = {}
    require("lspsaga.slist").list_map(self.list, function(node)
      local v = node.value
      if v and v.winline and v.winline > 0 then
        local k = item_key(incoming and v.from or v.to)
        groups[k] = groups[k] or {}
        table.insert(groups[k], v)
      end
    end)
    local ns = vim.api.nvim_create_namespace "SagaCallhierarchyDup"
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    self.dup_rows = {}
    for _, g in pairs(groups) do
      if #g > 1 then
        table.sort(g, function(a, b) return a.winline < b.winline end)
        local rows = vim.tbl_map(function(v) return v.winline end, g)
        for i, v in ipairs(g) do
          local line = lines[v.winline]
          if line then
            self.dup_rows[v.winline] = rows
            local mark = i == 1 and { virt_text = { { " ×" .. #g, "SagaCallhierarchyDupCount" } } }
              or {
                virt_text = { { " ↑ L" .. rows[1], "SagaCallhierarchyDupRef" } },
                end_col = #line,
                hl_group = "SagaCallhierarchyDup",
              }
            mark.virt_text_pos = "eol"
            pcall(
              vim.api.nvim_buf_set_extmark,
              buf,
              ns,
              v.winline - 1,
              i == 1 and 0 or math.min(v.inlevel, #line),
              mark
            )
          end
        end
      end
    end
    self:mark_cursor_duplicates()
  end

  mt.mark_cursor_duplicates = function(self)
    local buf, win = self.left_bufnr, self.left_winid
    if not (buf and vim.api.nvim_buf_is_valid(buf) and win and vim.api.nvim_win_is_valid(win)) then return end
    local ns = vim.api.nvim_create_namespace "SagaCallhierarchyDupCursor"
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local rows = self.dup_rows and self.dup_rows[vim.api.nvim_win_get_cursor(win)[1]]
    for _, r in ipairs(rows or {}) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, r - 1, 0, { line_hl_group = "SagaCallhierarchyDupCursor" })
    end
  end

  -- lspsaga edits the tree buffer in place on expand/collapse/request (not via redraw_tree), so
  -- refresh on every buffer change, once per batch of edits, after lspsaga has updated winlines.
  mt.track_duplicates = function(self)
    local buf, pending = self.left_bufnr, false
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if self.left_bufnr ~= buf then return true end -- tree closed: detach
        if pending then return end
        pending = true
        vim.schedule(function()
          pending = false
          if self.left_bufnr == buf then self:mark_duplicates() end
        end)
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = vim.api.nvim_create_augroup("SagaCallhierarchyDup", { clear = true }),
      buffer = buf,
      callback = function() self:mark_cursor_duplicates() end,
    })
    vim.keymap.set("n", "%", function()
      local cur = vim.api.nvim_win_get_cursor(self.left_winid)[1]
      local rows = self.dup_rows and self.dup_rows[cur]
      if not rows then return end
      local i = 1
      while rows[i] ~= cur do
        i = i + 1
      end
      vim.api.nvim_win_set_cursor(self.left_winid, { rows[i % #rows + 1], 4 })
    end, { buffer = buf, nowait = true, silent = true, desc = "Next occurrence of this call hierarchy entry" })
  end

  -- lspsaga's keymap() only binds the configured keys; add deletion on top for every tree it opens
  -- (initial render and restore_last both call keymap()): `dd` drops the entry under the cursor,
  -- and `d` over a visual selection drops every selected entry. `<C-q>` sends the tree to quickfix,
  -- `<`/`>` step through the history.
  -- keymap() runs once per new tree buffer, before its lines are set, so duplicate tracking hooks in here.
  local orig_keymap = mt.keymap
  mt.keymap = function(self)
    orig_keymap(self)
    self:track_duplicates()
    local entry = track(self)
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = vim.api.nvim_create_augroup("SagaCallhierarchyHistory", { clear = true }),
      buffer = self.left_bufnr,
      callback = function() entry.cursor = vim.api.nvim_win_get_cursor(0)[1] end,
    })
    vim.keymap.set(
      "n",
      "<",
      function() self:history_step(-1) end,
      { buffer = self.left_bufnr, nowait = true, silent = true, desc = "Older call hierarchy" }
    )
    vim.keymap.set(
      "n",
      ">",
      function() self:history_step(1) end,
      { buffer = self.left_bufnr, nowait = true, silent = true, desc = "Newer call hierarchy" }
    )
    vim.keymap.set(
      "n",
      "<C-q>",
      function() self:to_qflist() end,
      { buffer = self.left_bufnr, nowait = true, silent = true, desc = "Send call hierarchy to quickfix" }
    )
    vim.keymap.set("n", "dd", function()
      local l = vim.api.nvim_win_get_cursor(self.left_winid)[1]
      self:delete_range(l, l)
    end, { buffer = self.left_bufnr, nowait = true, silent = true, desc = "Delete entry from call hierarchy" })
    vim.keymap.set(
      "x",
      "d",
      function()
        local a, b = vim.fn.line "v", vim.fn.line "."
        -- leave visual mode before mutating the buffer, then prune the selected span
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        self:delete_range(math.min(a, b), math.max(a, b))
      end,
      { buffer = self.left_bufnr, nowait = true, silent = true, desc = "Delete selected entries from call hierarchy" }
    )
  end

  -- Reopen history entry `idx` (default: the one viewed last), or focus the tree if it's open.
  mt.restore_last = function(self, idx)
    if self.left_winid and vim.api.nvim_win_is_valid(self.left_winid) then
      return vim.api.nvim_set_current_win(self.left_winid)
    end
    local entry = history[idx or history_pos]
    if not entry then return vim.notify("[lspsaga] no call hierarchy to reopen", vim.log.levels.WARN) end
    if not vim.api.nvim_buf_is_valid(entry.main_buf) then entry.main_buf = vim.api.nvim_get_current_buf() end

    self.list, self.method, self.layout, self.main_buf = entry.list, entry.method, entry.layout, entry.main_buf
    local height = bit.rshift(vim.o.lines, 1) - 4
    local width = math.floor(vim.api.nvim_win_get_width(0) * saga_config.callhierarchy.left_width)
    self.left_bufnr, self.left_winid, self.right_bufnr, self.right_winid = require("lspsaga.layout")
      :new(self.layout)
      :left(height, width)
      :bufopt({ filetype = "sagacallhierarchy", buftype = "nofile", bufhidden = "wipe" })
      :right()
      :bufopt({ buftype = "nofile", bufhidden = "wipe" })
      :done()
    self:peek_view()
    self:keymap()

    -- preview buffers were unloaded/cleared by clean(); let peek_view reload them
    require("lspsaga.slist").list_map(self.list, function(node)
      node.value.bufnr, node.value.wipe, node.value.rendered = nil, nil, nil
    end)
    self:redraw_tree()
    local row = math.min(entry.cursor or 1, vim.api.nvim_buf_line_count(self.left_bufnr))
    vim.api.nvim_win_set_cursor(self.left_winid, { row, 4 })
  end

  -- `<` / `>`: replace the open tree with the older / newer one in the history.
  mt.history_step = function(self, delta)
    if self.pending_request then
      return vim.notify("[lspsaga] wait for the pending call hierarchy request", vim.log.levels.WARN)
    end
    local target = history_pos + delta
    if not history[target] then
      return vim.notify(
        ("[lspsaga] at %s call hierarchy (%d of %d)"):format(delta < 0 and "oldest" or "newest", history_pos, #history),
        vim.log.levels.WARN
      )
    end
    if self.left_winid and vim.api.nvim_win_is_valid(self.left_winid) then
      history[history_pos].cursor = vim.api.nvim_win_get_cursor(self.left_winid)[1]
    end
    require("lspsaga.util").close_win { self.left_winid, self.right_winid }
    self:clean()
    self:restore_last(target)
    local e = history[target]
    local root = e.list.value and (e.method == "callHierarchy/incomingCalls" and e.list.value.from or e.list.value.to)
    vim.api.nvim_echo({
      { ("call hierarchy %d of %d: "):format(target, #history) },
      {
        (e.method == "callHierarchy/incomingCalls" and "incoming " or "outgoing ") .. (root and root.name or "?"),
        "Title",
      },
    }, false, {})
  end
end

return M

-- Call hierarchy tree UI additions on top of lspsaga (installed by lua/plugins/lspsaga.lua).

local M = {}

function M.setup()
  -- Reopen the last call hierarchy tree, expansions included.
  --
  -- Every way out of the tree (quit, close, and the edit/split/tabe jumps) goes through
  -- `ch:clean()`, which nils every field on the instance. The tree itself is the `self.list`
  -- linked list: each node keeps its `inlevel`, `expand` state and `winline` (-1 when hidden
  -- under a collapsed parent), so holding on to it is enough to redraw the same view. The
  -- hook goes on the metatable because `clean()` would wipe anything set on the instance.
  local ch = require "lspsaga.callhierarchy"
  local mt = getmetatable(ch)
  local saga_config = require("lspsaga").config
  local last

  local orig_clean = mt.clean
  mt.clean = function(self)
    if self.list and self.list.value then
      last = { list = self.list, method = self.method, layout = self.layout, main_buf = self.main_buf }
    end
    return orig_clean(self)
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
    -- close first: clean() wipes the buffers peek_view loaded, which would orphan entries pointing at them
    require("lspsaga.util").close_win { self.left_winid, self.right_winid }
    self:clean()
    vim.fn.setqflist({}, " ", { title = title, items = items })
    vim.cmd "botright copen"
  end

  -- lspsaga's keymap() only binds the configured keys; add deletion on top for every tree it opens
  -- (initial render and restore_last both call keymap()): `dd` drops the entry under the cursor,
  -- and `d` over a visual selection drops every selected entry. `<C-q>` sends the tree to quickfix.
  local orig_keymap = mt.keymap
  mt.keymap = function(self)
    orig_keymap(self)
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

  mt.restore_last = function(self)
    if self.left_winid and vim.api.nvim_win_is_valid(self.left_winid) then
      return vim.api.nvim_set_current_win(self.left_winid)
    end
    if not last then return vim.notify("[lspsaga] no call hierarchy to reopen", vim.log.levels.WARN) end
    if not vim.api.nvim_buf_is_valid(last.main_buf) then last.main_buf = vim.api.nvim_get_current_buf() end

    self.list, self.method, self.layout, self.main_buf = last.list, last.method, last.layout, last.main_buf
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

    -- preview buffers were wiped/cleared by clean(); let peek_view reload them
    require("lspsaga.slist").list_map(self.list, function(node)
      node.value.bufnr, node.value.wipe, node.value.rendered = nil, nil, nil
    end)
    self:redraw_tree()
    vim.api.nvim_win_set_cursor(self.left_winid, { 1, 4 })
  end
end

return M

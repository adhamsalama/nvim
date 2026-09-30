-- Lspsaga, used *only* for its call hierarchy tree.
--
-- Deliberately not using the `astrocommunity.lsp.lspsaga-nvim` pack: that one also remaps
-- `K`, `gd`, rename, code action and the diagnostic jumps over AstroNvim's defaults.
-- Here the plugin stays unloaded until `:Lspsaga` or one of the two keymaps below is used.
--
-- `saga.setup()` only has three load-time side effects (lspsaga/init.lua:203-222):
--   * lightbulb autocmd            -> disabled below
--   * symbol:register_module()     -> runs unconditionally, but every branch inside is gated
--                                     on `symbol_in_winbar.enable` / `implement.enable`
--   * diagnostic_only_current      -> already false by default
-- Everything else in lspsaga is command-triggered, so leaving it unmapped keeps it inert.

---@type LazySpec
return {
  "nvimdev/lspsaga.nvim",
  cmd = "Lspsaga",
  keys = {
    { "<Leader>lc", "<Cmd>Lspsaga incoming_calls<CR>", desc = "Incoming calls" },
    { "<Leader>lC", "<Cmd>Lspsaga outgoing_calls<CR>", desc = "Outgoing calls" },
    {
      "<Leader>lv",
      function() require("lspsaga.callhierarchy"):restore_last() end,
      desc = "Reopen last call hierarchy",
    },
  },
  opts = {
    -- we have our own winbar (see `lua/plugins/astroui.lua`)
    symbol_in_winbar = { enable = false },
    lightbulb = { enable = false },
    implement = { enable = false },
    beacon = { enable = false },
    callhierarchy = {
      layout = "float",
      keys = {
        edit = "<CR>",
        vsplit = "s",
        split = "i",
        tabe = "t",
        quit = "q",
        close = "<C-c>k",
        shuttle = "[w",
        toggle_or_req = "<Tab>", -- expand a node to request the next level
      },
    },
  },
  config = function(_, opts)
    require("lspsaga").setup(opts)

    -- Preview/jump to the actual call site, the way VS Code does.
    --
    -- For incoming calls the protocol provides `fromRanges` — where inside the caller the call
    -- happens — but lspsaga only ever reads `from.selectionRange`, the caller's declaration
    -- (callhierarchy.lua:248 for the jump, :294 for the preview); `fromRanges` appears nowhere
    -- in the plugin. It does keep the whole result object as the node value, so the ranges are
    -- already in memory, just unused.
    --
    -- So: swap in the call site for display, and restore the declaration on the way back out.
    -- The restore matters — `toggle_or_request` sends the same item back to fetch the next
    -- level, and a rewritten selectionRange would resolve to the wrong symbol and break
    -- expansion. Outgoing calls are left alone: their `fromRanges` are in the *current* file,
    -- not in `to`, so `to.selectionRange` is already correct there.
    --
    -- Callers the server can't name come back as the whole module: a `File`/`Module` item named by its
    -- path. tsserver does this for functions under computed keys, e.g.
    -- `export default { [PRODUCTS__UPDATE_PRODUCT]: async (req, res) => { ... } }`. For those,
    -- each call site gets its own entry, named from the enclosing key/variable via treesitter.
    local util = require "lspsaga.util"
    local FILE_KINDS, FUNCTION_KIND = { [1] = true, [2] = true }, 12 -- File, Module
    local fn_types =
      { arrow_function = true, function_expression = true, ["function"] = true, generator_function = true }

    local function enclosing_name(uri, pos)
      local bufnr = vim.uri_to_bufnr(uri)
      vim.fn.bufload(bufnr)
      local ft = vim.bo[bufnr].filetype
      if ft == "" then ft = vim.filetype.match { buf = bufnr } or "" end
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, vim.treesitter.language.get_lang(ft) or ft)
      if not ok or not parser then return end
      parser:parse()
      local node =
        vim.treesitter.get_node { bufnr = bufnr, pos = { pos.line, pos.character }, ignore_injections = false }
      while node do
        local parent = node:parent()
        if fn_types[node:type()] and parent then
          local name = parent:field("key")[1] or parent:field("name")[1] or parent:field("left")[1]
          if name then return (vim.treesitter.get_node_text(name, bufnr):gsub("^%[(.*)%]$", "%1")) end
        end
        node = parent
      end
    end

    local orig_request = util.client_request
    util.client_request = function(client, method, params, handler, ...)
      if type(params) == "table" and type(params.item) == "table" and params.item.__decl_range then
        local item = vim.deepcopy(params.item)
        item.selectionRange, item.__decl_range = item.__decl_range, nil
        item.name, item.kind = item.__orig_name or item.name, item.__orig_kind or item.kind
        item.__orig_name, item.__orig_kind = nil, nil
        params = vim.tbl_extend("force", params, { item = item })
      end
      if method == "callHierarchy/incomingCalls" and type(handler) == "function" then
        local inner = handler
        handler = function(err, res, ...)
          if type(res) == "table" then
            local out = {}
            for _, call in ipairs(res) do
              local from = type(call.from) == "table" and call.from
              local ranges = type(call.fromRanges) == "table" and call.fromRanges or {}
              if from and FILE_KINDS[from.kind] and #ranges > 0 and not from.__decl_range then
                for _, site in ipairs(ranges) do
                  local ok, name = pcall(enclosing_name, from.uri, site.start)
                  local item = vim.deepcopy(from)
                  item.__decl_range, item.selectionRange = item.selectionRange, site
                  if ok and name then
                    item.__orig_name, item.__orig_kind = item.name, item.kind
                    item.name, item.kind = name, FUNCTION_KIND
                  end
                  out[#out + 1] = vim.tbl_extend("force", call, { from = item, fromRanges = { site } })
                end
              else
                if from and ranges[1] and not from.__decl_range then
                  from.__decl_range = from.selectionRange
                  from.selectionRange = ranges[1]
                end
                out[#out + 1] = call
              end
            end
            res = out
          end
          return inner(err, res, ...)
        end
      end
      return orig_request(client, method, params, handler, ...)
    end

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

      local incoming = self.method == "callHierarchy/incomingCalls"
      local visible, lines = {}, {}
      require("lspsaga.slist").list_map(self.list, function(node)
        local v = node.value
        -- preview buffers were wiped/cleared by clean(); let peek_view reload them
        v.bufnr, v.wipe, v.rendered = nil, nil, nil
        if v.winline and v.winline > 0 then
          visible[#visible + 1] = v
          lines[v.winline] = (" "):rep(v.inlevel) .. (incoming and v.from or v.to).name
        end
      end)

      vim.bo[self.left_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.left_bufnr, 0, -1, false, lines)
      local kind = require("lspsaga.lspkind").kind
      local ns = vim.api.nvim_create_namespace "SagaCallhierarchy"
      for _, v in ipairs(visible) do
        local row = v.winline - 1
        self:set_toggle_icon(
          v.expand and saga_config.ui.collapse or saga_config.ui.expand,
          row,
          v.inlevel - 4,
          v.virtid
        )
        local k = kind[(incoming and v.from or v.to).kind]
        vim.api.nvim_buf_set_extmark(self.left_bufnr, ns, row, v.inlevel - 2, {
          virt_text = { { k[2], "Saga" .. k[3] } },
          virt_text_pos = "overlay",
        })
        self:render_virtline(row, v.inlevel)
      end
      vim.bo[self.left_bufnr].modifiable = false
      vim.api.nvim_win_set_cursor(self.left_winid, { 1, 4 })
    end
  end,
}

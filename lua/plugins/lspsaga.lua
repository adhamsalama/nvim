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
    --
    -- Such handlers are never called directly either, only passed around (`Router.put(path,
    -- Controller[KEY])`), so asking for their incoming calls finds nothing. Expanding one sends
    -- `textDocument/references` on its key instead, and lists the `X[KEY]` lookups as the next
    -- level — "used by" rather than "called by". References that are calls (`obj.fn()`) become
    -- expandable callers, so the same trick covers `{ name: async () => {} }` style code, where
    -- tsserver has no call hierarchy at all (see `prepare_fallback`).
    local util = require "lspsaga.util"
    local orig_request = util.client_request
    local FILE_KINDS, FUNCTION_KIND = { [1] = true, [2] = true }, 12 -- File, Module
    local fn_types =
      { arrow_function = true, function_expression = true, ["function"] = true, generator_function = true }

    local function ts_node_at(uri, pos)
      local bufnr = vim.uri_to_bufnr(uri)
      vim.fn.bufload(bufnr)
      local ft = vim.bo[bufnr].filetype
      if ft == "" then ft = vim.filetype.match { buf = bufnr } or "" end
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, vim.treesitter.language.get_lang(ft) or ft)
      if not ok or not parser then return end
      parser:parse()
      return bufnr,
        vim.treesitter.get_node { bufnr = bufnr, pos = { pos.line, pos.character }, ignore_injections = false }
    end

    -- name of the function enclosing `pos`, plus where to ask for references to it
    local function enclosing_name(uri, pos)
      local bufnr, node = ts_node_at(uri, pos)
      while node do
        local parent = node:parent()
        if fn_types[node:type()] and parent then
          local name = parent:field("key")[1] or parent:field("name")[1] or parent:field("left")[1]
          if name then
            -- for `[KEY]: ...` reference the constant, not the brackets
            local target = name:type() == "computed_property_name" and name:named_child(0) or name
            local row, col = target:start()
            return (vim.treesitter.get_node_text(name, bufnr):gsub("^%[(.*)%]$", "%1")), { line = row, character = col }
          end
        end
        node = parent
      end
    end

    local function text(node, bufnr) return vim.treesitter.get_node_text(node, bufnr) end
    local function lsp_range(node)
      local sr, sc, er, ec = node:range()
      return { start = { line = sr, character = sc }, ["end"] = { line = er, character = ec } }
    end

    -- Turn one reference to a function's name into a hierarchy entry, or nil to skip it:
    --   * `obj.fn(...)` / `fn(...)` is a call: named after the enclosing function and expandable,
    --     so the chain keeps going through functions tsserver can't do call hierarchy for
    --   * `Controller[KEY]` / `middleware.fn` passed along is a use: a leaf labelled by the
    --     outermost call it sits in, e.g. `Router.put('/:productId') · Controller`
    --   * definitions (`fn: {...}` in another object), imports, strings: skipped
    local function reference_entry(loc)
      local bufnr, node = ts_node_at(loc.uri, loc.range.start)
      local parent = node and node:parent()
      if not parent then return end
      local access = (parent:type() == "member_expression" and parent:field("property")[1] == node)
        or (parent:type() == "subscript_expression" and parent:field("index")[1] == node)
      local callee = access and parent or node
      local call = callee:parent()
      local entry = { kind = FUNCTION_KIND, uri = loc.uri, range = loc.range, selectionRange = loc.range }

      if call and call:type() == "call_expression" and call:field("function")[1] == callee then
        local name, ref_pos = enclosing_name(loc.uri, loc.range.start)
        entry.name = name or ("%s:%d"):format(vim.fs.basename(vim.uri_to_fname(loc.uri)), loc.range.start.line + 1)
        entry.__ref_pos, entry.__ref_leaf = ref_pos, not ref_pos or nil
        return entry
      end
      if not access then return end

      local object = text(parent:field("object")[1], bufnr)
      local outer
      for n in function(_, cur) return cur:parent() end, nil, parent do
        if n:type() == "arguments" and n:parent() and n:parent():type() == "call_expression" then outer = n end
      end
      if outer then
        local first = outer:named_child(0)
        local arg = first and first:type() == "string" and text(first, bufnr) or ""
        entry.name = ("%s(%s) · %s"):format(text(outer:parent():field("function")[1], bufnr), arg, object)
      else
        entry.name = parent:type() == "subscript_expression" and ("%s[…]"):format(object) or text(parent, bufnr)
      end
      entry.__ref_leaf = true
      return entry
    end

    local function request_references(client, item, handler)
      local params = {
        textDocument = { uri = item.uri },
        position = item.__ref_pos,
        context = { includeDeclaration = false },
      }
      return orig_request(client, "textDocument/references", params, function(err, locs, ...)
        local calls = {}
        for _, loc in ipairs(locs or {}) do
          local ok, entry = pcall(reference_entry, loc)
          if ok and entry then calls[#calls + 1] = { from = entry, fromRanges = { loc.range } } end
        end
        return handler(err, calls, ...)
      end)
    end

    -- tsserver has no call hierarchy item for a function stored in an object property
    -- (`name: async () => {}` / `name: function () {}`), so prepare returns nothing. With the
    -- cursor on such a name, build the root item here and let references drive the expansion.
    local function prepare_fallback(params)
      local uri = params.textDocument.uri
      local bufnr, node = ts_node_at(uri, params.position)
      for _ = 1, 3 do
        if not node then return end
        local parent = node:parent()
        if parent and parent:type() == "pair" and parent:field("key")[1] == node then
          local value = parent:field("value")[1]
          if not (value and fn_types[value:type()]) then return end
          local target = node:type() == "computed_property_name" and node:named_child(0) or node
          local row, col = target:start()
          return {
            name = (text(node, bufnr):gsub("^%[(.*)%]$", "%1")),
            kind = FUNCTION_KIND,
            uri = uri,
            range = lsp_range(parent),
            selectionRange = lsp_range(node),
            __ref_pos = { line = row, character = col },
          }
        end
        node = parent
      end
    end

    util.client_request = function(client, method, params, handler, ...)
      local item = type(params) == "table" and type(params.item) == "table" and params.item
      if method == "callHierarchy/incomingCalls" and item and type(handler) == "function" then
        if item.__ref_leaf then
          return vim.schedule(function() handler(nil, {}) end)
        end
        if item.__ref_pos then return request_references(client, item, handler) end
      end
      if method == "textDocument/prepareCallHierarchy" and type(handler) == "function" then
        local inner = handler
        handler = function(err, res, ...)
          if not err and (res == nil or vim.tbl_isempty(res)) then
            local ok, fallback = pcall(prepare_fallback, params)
            if ok and fallback then res = { fallback } end
          end
          return inner(err, res, ...)
        end
      end
      if item and item.__decl_range then
        item = vim.deepcopy(item)
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
                  local ok, name, ref_pos = pcall(enclosing_name, from.uri, site.start)
                  local synth = vim.deepcopy(from)
                  synth.__decl_range, synth.selectionRange = synth.selectionRange, site
                  if ok and name then
                    synth.__orig_name, synth.__orig_kind = synth.name, synth.kind
                    synth.name, synth.kind, synth.__ref_pos = name, FUNCTION_KIND, ref_pos
                  end
                  out[#out + 1] = vim.tbl_extend("force", call, { from = synth, fromRanges = { site } })
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

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

    -- shared with the `grr` override (lua/plugins/tsgo-references.lua) via lua/utils/tsgo.lua
    local tsgo = require "utils.tsgo"
    local load_buf, ts_node_at, ensure_attached = tsgo.load_buf, tsgo.ts_node_at, tsgo.ensure_attached

    -- name of the function enclosing `pos`, plus where to ask for references to it.
    -- `method_definition` / `function_declaration` carry their own `name`; arrow and function
    -- expressions are anonymous, so take the key/name/left of whatever binds them.
    local function enclosing_name(uri, pos)
      local bufnr, node = ts_node_at(uri, pos)
      while node do
        local t = node:type()
        local name
        if t == "method_definition" or t == "function_declaration" then
          name = node:field("name")[1]
        elseif fn_types[t] then
          local parent = node:parent()
          name = parent and (parent:field("key")[1] or parent:field("name")[1] or parent:field("left")[1])
        end
        if name then
          -- for `[KEY]: ...` reference the constant, not the brackets
          local target = name:type() == "computed_property_name" and name:named_child(0) or name
          local row, col = target:start()
          return (vim.treesitter.get_node_text(name, bufnr):gsub("^%[(.*)%]$", "%1")), { line = row, character = col }
        end
        node = node:parent()
      end
    end

    -- file-level entries show the path relative to cwd (absolute if outside it)
    local function rel_path(uri) return vim.fn.fnamemodify(vim.uri_to_fname(uri), ":.") end

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
        entry.name = name or ("%s:%d"):format(rel_path(loc.uri), loc.range.start.line + 1)
        entry.__ref_pos, entry.__ref_leaf = ref_pos, not ref_pos or nil
        return entry
      end
      -- a bare `fn` handed to a call, e.g. `Router.get(path, auth, fn)`
      local passed = not access and parent:type() == "arguments"
      if not (access or passed) then return end

      local object = passed and text(node, bufnr) or text(parent:field("object")[1], bufnr)
      local outer
      for n in function(_, cur) return cur:parent() end, nil, node do
        if n:type() == "arguments" and n:parent() and n:parent():type() == "call_expression" then outer = n end
      end
      if passed and not outer then return end -- `new X(fn)` and the like
      if outer then
        local first = outer:named_child(0)
        local arg = first and first:type() == "string" and text(first, bufnr) or ""
        entry.name = ("%s(%s) · %s"):format(text(outer:parent():field("function")[1], bufnr), arg, object)
      elseif not passed then
        entry.name = parent:type() == "subscript_expression" and ("%s[…]"):format(object) or text(parent, bufnr)
      end
      entry.__ref_leaf = true
      return entry
    end

    -- tsgo doesn't follow CommonJS exports across files: references to a function exported as
    -- `module.exports = { fn }` stop at that shorthand. Find the files importing it by name
    -- (`const { fn } = require(...)` / `import { fn }`), keep the imports that resolve to one of
    -- `exports`, and return the references found from there.
    local import_types = { shorthand_property_identifier_pattern = true, import_specifier = true }
    local function importer_references(client, name, exports, cb)
      local rg = vim
        .system({ "rg", "--vimgrep", "-wF", "--glob", "!node_modules", "--type", "js", "--type", "ts", name, "." }, {
          text = true,
        })
        :wait()
      local cands = {}
      for line in vim.gsplit(rg.stdout or "", "\n", { trimempty = true }) do
        local file, lnum, col = line:match "^(.-):(%d+):(%d+):"
        if file then
          local uri = vim.uri_from_fname(vim.fn.fnamemodify(file, ":p"))
          local pos = { line = tonumber(lnum) - 1, character = tonumber(col) - 1 }
          local ok, bufnr, node = pcall(ts_node_at, uri, pos)
          if
            ok
            and node
            and (import_types[node:type()] or import_types[node:parent() and node:parent():type() or ""])
          then
            cands[#cands + 1] = { uri = uri, pos = pos, bufnr = bufnr }
          end
        end
      end
      local out, pending = {}, #cands
      if pending == 0 then
        return vim.schedule(function() cb(out) end)
      end
      local function done()
        pending = pending - 1
        if pending == 0 then cb(out) end
      end
      for _, cand in ipairs(cands) do
        ensure_attached(client, cand.bufnr)
        local params = { textDocument = { uri = cand.uri }, position = cand.pos }
        orig_request(client, "textDocument/definition", params, function(_, res)
          local hit = false
          for _, d in ipairs(res and (res.uri or res.targetUri) and { res } or res or {}) do
            local r = d.targetSelectionRange or d.range
            hit = hit or exports[("%s:%d:%d"):format(d.targetUri or d.uri, r.start.line, r.start.character)]
          end
          if not hit then return done() end
          params.context = { includeDeclaration = false }
          orig_request(client, "textDocument/references", params, function(_, locs)
            vim.list_extend(out, locs or {})
            done()
          end, cand.bufnr)
        end, cand.bufnr)
      end
    end

    local function request_references(client, item, handler)
      local params = {
        textDocument = { uri = item.uri },
        position = item.__ref_pos,
        context = { includeDeclaration = false },
      }
      return orig_request(client, "textDocument/references", params, function(err, locs, ...)
        local calls, exports, name, seen = {}, {}, nil, {}
        local function key(loc) return ("%s:%d:%d"):format(loc.uri, loc.range.start.line, loc.range.start.character) end
        -- `follow` is set only on the server's own results: a shorthand there (`export default { fn }`
        -- / `module.exports = { fn }`) is the barrier tsgo stops references at, not a call, so record
        -- it and chase through it rather than listing it. `seen` keeps the re-requests below from
        -- re-adding the shorthand or double-counting a site two of them both return.
        local function add(list, follow)
          for _, loc in ipairs(list) do
            if not seen[key(loc)] then
              seen[key(loc)] = true
              local ok, bufnr, node = pcall(ts_node_at, loc.uri, loc.range.start)
              if follow and ok and node and node:type() == "shorthand_property_identifier" then
                exports[key(loc)] = loc
                name = text(node, bufnr)
              else
                local ok2, entry = pcall(reference_entry, loc)
                if ok2 and entry then calls[#calls + 1] = { from = entry, fromRanges = { loc.range } } end
              end
            end
          end
        end
        add(locs or {}, true)
        if not name then return handler(err, calls, ...) end
        local rest = { ... }

        -- Callers reach a function parked in an export object two ways, and the query on its
        -- declaration follows neither:
        --   * `import Obj from '...'; Obj.fn()` — tsgo *does* resolve these, but only when references
        --     are requested at the property inside the export object, so ask there.
        --   * `const { fn } = require('...')` / `import { fn }` — named, so `importer_references`
        --     finds the importing files and asks from each.
        local pending = 1
        local function finish()
          pending = pending - 1
          if pending == 0 then handler(err, calls, unpack(rest)) end
        end
        for _, loc in pairs(exports) do
          pending = pending + 1
          local bufnr = load_buf(loc.uri)
          ensure_attached(client, bufnr)
          orig_request(client, "textDocument/references", {
            textDocument = { uri = loc.uri },
            position = loc.range.start,
            context = { includeDeclaration = false },
          }, function(_, more)
            add(more or {}, false)
            finish()
          end, bufnr)
        end
        importer_references(client, name, exports, function(more)
          add(more, false)
          finish()
        end)
      end)
    end

    -- Outgoing calls for items tsserver doesn't know (the `prepare_fallback` root, and every entry
    -- this produces): walk the function body with treesitter, resolve each call with
    -- `textDocument/definition`, and keep only targets inside cwd and outside node_modules, which
    -- drops `_.get`, `res.status()` and friends. Entries are grouped per target and expand the
    -- same way, so class methods, `const` functions and property arrows all chain alike.
    local function function_node_at(uri, pos)
      local bufnr, node = ts_node_at(uri, pos)
      for _ = 1, 5 do
        if not node then return end
        local t = node:type()
        if t == "method_definition" or t == "function_declaration" or fn_types[t] then return bufnr, node end
        if t == "pair" or t == "variable_declarator" or t == "assignment_expression" then
          local value = node:field("value")[1] or node:field("right")[1]
          if value and fn_types[value:type()] then return bufnr, value end
        end
        node = node:parent()
      end
    end

    local function collect_calls(node, acc)
      for child in node:iter_children() do
        if child:named() then
          if child:type() == "call_expression" then
            local callee = child:field("function")[1]
            local target = callee and callee:type() == "member_expression" and callee:field("property")[1]
              or (callee and callee:type() == "identifier" and callee)
            if target then acc[#acc + 1] = { callee = callee, target = target } end
          end
          collect_calls(child, acc)
        end
      end
      return acc
    end

    local function request_outgoing(client, item, handler)
      local bufnr, fn_node = function_node_at(item.uri, item.selectionRange.start)
      if not fn_node then
        return vim.schedule(function() handler(nil, {}) end)
      end
      ensure_attached(client, bufnr)
      local calls = collect_calls(fn_node, {})
      if #calls == 0 then
        return vim.schedule(function() handler(nil, {}) end)
      end

      local cwd = vim.fs.normalize(vim.fn.getcwd()) .. "/"
      local by_target, order, pending = {}, {}, #calls
      local function done()
        pending = pending - 1
        if pending > 0 then return end
        -- responses arrive in any order; list targets by their first call in the body
        table.sort(order, function(a, b) return by_target[a].__idx < by_target[b].__idx end)
        local out = {}
        for _, key in ipairs(order) do
          out[#out + 1] = by_target[key]
        end
        handler(nil, out)
      end
      for idx, call in ipairs(calls) do
        local row, col = call.target:start()
        orig_request(client, "textDocument/definition", {
          textDocument = { uri = item.uri },
          position = { line = row, character = col },
        }, function(_, res)
          local loc = res and (res.uri or res.targetUri) and res or (type(res) == "table" and res[1])
          local uri = loc and (loc.uri or loc.targetUri)
          local range = loc and (loc.targetSelectionRange or loc.range)
          local fname = uri and vim.fs.normalize(vim.uri_to_fname(uri))
          if fname and vim.startswith(fname, cwd) and not fname:find("/node_modules/", 1, true) then
            local key = ("%s:%d:%d"):format(uri, range.start.line, range.start.character)
            local site = lsp_range(call.callee)
            if by_target[key] then
              table.insert(by_target[key].fromRanges, site)
              by_target[key].__idx = math.min(by_target[key].__idx, idx)
            else
              order[#order + 1] = key
              by_target[key] = {
                to = {
                  name = (text(call.callee, bufnr):gsub("%s+", "")),
                  kind = FUNCTION_KIND,
                  uri = uri,
                  range = range,
                  selectionRange = range,
                  __out_synth = true,
                },
                fromRanges = { site },
                __idx = idx,
              }
            end
          end
          done()
        end, bufnr)
      end
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

    -- tsserver only prepares a call hierarchy with the cursor exactly on the function's name. With it
    -- elsewhere on the declaration line (`async`, the indent, the parameters), point at the name.
    local function declaration_name_pos(params)
      local bufnr = load_buf(params.textDocument.uri)
      local pos = vim.deepcopy(params.position)
      local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
      pos.character = math.max(pos.character, #line:match "^%s*")
      local _, node = ts_node_at(params.textDocument.uri, pos)
      while node do
        local t, name, fn = node:type()
        if t == "method_definition" or t == "function_declaration" then
          name, fn = node:field("name")[1], node
        elseif t == "pair" or t == "variable_declarator" then
          local value = node:field("value")[1]
          if value and fn_types[value:type()] then
            name, fn = node:field("key")[1] or node:field("name")[1], value
          end
        end
        if name then
          local body = fn:field("body")[1]
          local br, bc = (body or fn):start()
          if pos.line > br or (pos.line == br and pos.character >= bc) then return end
          local target = name:type() == "computed_property_name" and name:named_child(0) or name
          local row, col = target:start()
          return { line = row, character = col }
        end
        node = node:parent()
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
      if method == "callHierarchy/outgoingCalls" and item and type(handler) == "function" then
        if item.__out_synth or item.__ref_pos then return request_outgoing(client, item, handler) end
      end
      if method == "textDocument/prepareCallHierarchy" and type(handler) == "function" then
        local inner = handler
        local tried_decl, tried_def, req_args = false, false, { ... }
        local function on_result(err, res, ...)
          local rest = { ... }
          -- last resort: a function parked in an object property, which tsgo can't prepare
          local function finish()
            if not err and (res == nil or vim.tbl_isempty(res)) then
              local ok, fallback = pcall(prepare_fallback, params)
              if ok and fallback then res = { fallback } end
            end
            return inner(err, res, unpack(rest))
          end
          if err or not (res == nil or vim.tbl_isempty(res)) then return finish() end
          -- cursor on the declaration line but off the name (indent, `async`, params): aim at the name
          if not tried_decl then
            tried_decl = true
            local ok, pos = pcall(declaration_name_pos, params)
            if ok and pos and (pos.line ~= params.position.line or pos.character ~= params.position.character) then
              params = vim.tbl_extend("force", params, { position = pos })
              return orig_request(client, method, params, on_result, unpack(req_args))
            end
          end
          -- cursor on a re-export shorthand / alias (`export default { fn }`): tsgo won't prepare
          -- there, but resolves its definition to the real declaration, where prepare works
          if not tried_def then
            tried_def = true
            return orig_request(client, "textDocument/definition", {
              textDocument = params.textDocument,
              position = params.position,
            }, function(_, dres)
              local d = type(dres) == "table" and ((dres.uri or dres.targetUri) and dres or dres[1])
              local uri = d and (d.targetUri or d.uri)
              local r = d and (d.targetSelectionRange or d.range)
              if
                uri
                and r
                and (
                  uri ~= params.textDocument.uri
                  or r.start.line ~= params.position.line
                  or r.start.character ~= params.position.character
                )
              then
                ensure_attached(client, load_buf(uri))
                params = vim.tbl_extend("force", params, { textDocument = { uri = uri }, position = r.start })
                return orig_request(client, method, params, on_result, unpack(req_args))
              end
              return finish()
            end, unpack(req_args))
          end
          return finish()
        end
        handler = on_result
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
        -- no callers at all: the function is likely only passed around (`Router.get(path, fn)`),
        -- so list where it's used instead
        local ref_item = params.item
        handler = function(err, res, ...)
          if not err and ref_item and (res == nil or vim.tbl_isempty(res)) and not ref_item.__ref_pos then
            ref_item = vim.tbl_extend("force", ref_item, { __ref_pos = ref_item.selectionRange.start })
            return request_references(client, ref_item, inner)
          end
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
                  else
                    synth.__orig_name, synth.name = synth.name, rel_path(synth.uri)
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

-- LSP reference counts shown as virtual lines above functions/methods/classes.
--
-- Only definitions in (or near) the visible part of each window are counted, results are cached per buffer
-- changedtick, in-flight requests are cancelled when a newer refresh starts, and the extmarks are swapped in one go
-- once every request has answered. Autocmds only exist while the feature is enabled.

local M = {}

local ns = vim.api.nvim_create_namespace "lsp_ref_count"
local augroup = "LspRefCount"
local DEBOUNCE_MS = 600
local MARGIN = 50 -- extra lines above/below the visible window to count as well

local enabled = false
local generation = 0 -- bumped on any write: counts may change after editing any file
local states = {} ---@type table<integer, table>

-- LSP SymbolKind values that get a count in the documentSymbol fallback
local symbol_kinds = { [5] = true, [6] = true, [9] = true, [10] = true, [11] = true, [12] = true, [23] = true }
local lang_map = { typescriptreact = "tsx", javascriptreact = "javascript" }

-- Languages with a Treesitter query use it (so e.g. arrow functions assigned to variables get a count); every other
-- language falls back to LSP document symbols.
local query_strs = {
  javascript = [[
    (function_declaration name: (identifier) @name)
    (method_definition name: (property_identifier) @name)
    (variable_declarator name: (identifier) @name value: [(arrow_function) (function_expression)])
  ]],
  go = [[
    (function_declaration name: (identifier) @name)
    (method_declaration name: (field_identifier) @name)
    (type_declaration (type_spec name: (type_identifier) @name type: (struct_type)))
  ]],
}
query_strs.typescript = query_strs.javascript
  .. [[
  (public_field_definition name: (property_identifier) @name value: [(arrow_function) (function_expression)])
]]
query_strs.tsx = query_strs.typescript

local queries = {}
local function get_query(lang)
  if queries[lang] == nil then
    local ok, q = false, nil
    if query_strs[lang] then
      ok, q = pcall(vim.treesitter.query.parse, lang, query_strs[lang])
    end
    queries[lang] = ok and q or false
  end
  return queries[lang]
end

local function buf_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  return lang_map[ft] or ft
end

local function supported(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and not vim.b[bufnr].large_buf
    and #vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/references" } > 0
end

local function state(bufnr)
  states[bufnr] = states[bufnr] or { cancels = {} }
  return states[bufnr]
end

local function cancel(s)
  for _, c in ipairs(s.cancels) do
    pcall(c)
  end
  s.cancels = {}
  s.token = nil
end

-- 0-based [first, last] row range covering every window showing the buffer, plus a margin
local function visible_range(bufnr)
  local first, last
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local top, bot = unpack(vim.api.nvim_win_call(win, function() return { vim.fn.line "w0", vim.fn.line "w$" } end))
    first = math.min(first or top, top)
    last = math.max(last or bot, bot)
  end
  if not first then return nil end
  return math.max(first - 1 - MARGIN, 0), last - 1 + MARGIN
end

-- Calls cb with a list of { row, col } (0-based) for every definition that should get a count.
local function get_positions(bufnr, cb)
  local lang = buf_lang(bufnr)
  local query = get_query(lang)
  if query then
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    local tree = ok and parser and parser:parse()[1]
    if not tree then return cb {} end
    local positions = {}
    for _, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
      local row, col = node:start()
      table.insert(positions, { row, col })
    end
    return cb(positions)
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  return vim.lsp.buf_request_all(bufnr, "textDocument/documentSymbol", params, function(results)
    local positions, seen = {}, {}
    local function walk(symbols)
      for _, sym in ipairs(symbols or {}) do
        -- DocumentSymbol has selectionRange; SymbolInformation only has location.range
        local range = sym.selectionRange or (sym.location and sym.location.range)
        if range and symbol_kinds[sym.kind] then
          local key = range.start.line .. ":" .. range.start.character
          if not seen[key] then
            seen[key] = true
            table.insert(positions, { range.start.line, range.start.character })
          end
        end
        walk(sym.children)
      end
    end
    for _, res in pairs(results) do
      walk(res.result)
    end
    cb(positions)
  end)
end

local function key_of(pos) return pos[1] .. ":" .. pos[2] end

local function render(bufnr, s)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local tabstop = string.rep(" ", vim.bo[bufnr].tabstop)
  for _, pos in ipairs(s.positions or {}) do
    local count = s.counts[key_of(pos)]
    if count then
      local line = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1] or ""
      local padding = line:match("^%s*"):gsub("\t", tabstop)
      local label = count == 1 and "1 reference" or (count .. " references")
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, pos[1], 0, {
        virt_lines = { { { padding .. label, "Comment" } } },
        virt_lines_above = true,
      })
    end
  end
end

local function refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not enabled then return end
  if not supported(bufnr) then
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
    return
  end

  local s = state(bufnr)
  cancel(s)
  local tick = vim.b[bufnr].changedtick
  if s.tick ~= tick or s.gen ~= generation then
    -- Keep the old marks on screen until the new counts are in; just drop the cached data.
    s.tick, s.gen, s.counts, s.positions = tick, generation, {}, nil
  end

  local token = {}
  s.token = token
  local function alive()
    return enabled and s.token == token and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].changedtick == tick
  end

  local function with_positions(positions)
    if not alive() then return end
    s.positions = positions
    local first, last = visible_range(bufnr)
    if not first then return end

    local pending = 0
    local function done()
      pending = pending - 1
      if pending == 0 and alive() then
        s.cancels = {}
        render(bufnr, s)
      end
    end

    for _, pos in ipairs(positions) do
      local key = key_of(pos)
      if pos[1] >= first and pos[1] <= last and not s.counts[key] then
        pending = pending + 1
        local params = {
          textDocument = vim.lsp.util.make_text_document_params(bufnr),
          position = { line = pos[1], character = pos[2] },
          context = { includeDeclaration = false },
        }
        local c = vim.lsp.buf_request_all(bufnr, "textDocument/references", params, function(results)
          if not alive() then return end
          local seen, count = {}, 0
          for _, res in pairs(results) do
            for _, ref in ipairs(res.result or {}) do
              local k = (ref.uri or "") .. ref.range.start.line .. ":" .. ref.range.start.character
              if not seen[k] then
                seen[k] = true
                count = count + 1
              end
            end
          end
          s.counts[key] = count
          done()
        end)
        table.insert(s.cancels, c)
      end
    end
    if pending == 0 then render(bufnr, s) end
  end

  if s.positions then return with_positions(s.positions) end
  local c = get_positions(bufnr, with_positions)
  if type(c) == "function" then table.insert(s.cancels, c) end
end

local function schedule(bufnr)
  local s = state(bufnr)
  if s.timer then s.timer:stop() end
  s.timer = vim.defer_fn(function()
    s.timer = nil
    refresh(bufnr)
  end, DEBOUNCE_MS)
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup(augroup, { clear = true })
  local function on(events, callback) vim.api.nvim_create_autocmd(events, { group = group, callback = callback }) end

  on({ "BufEnter", "LspAttach", "TextChanged" }, function(args) schedule(args.buf) end)
  on("BufWritePost", function(args)
    generation = generation + 1 -- references from/to other files may have changed
    schedule(args.buf)
  end)
  on("WinScrolled", function()
    local seen = {}
    for win in pairs(vim.v.event) do
      local id = tonumber(win)
      if id and vim.api.nvim_win_is_valid(id) then
        local buf = vim.api.nvim_win_get_buf(id)
        if not seen[buf] then
          seen[buf] = true
          schedule(buf)
        end
      end
    end
  end)
  on({ "BufDelete", "BufWipeout" }, function(args)
    local s = states[args.buf]
    if s then
      cancel(s)
      if s.timer then s.timer:stop() end
      states[args.buf] = nil
    end
  end)
end

function M.enable()
  enabled = true
  create_autocmds()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    refresh(vim.api.nvim_win_get_buf(win))
  end
end

function M.disable()
  enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, augroup)
  for bufnr, s in pairs(states) do
    cancel(s)
    if s.timer then s.timer:stop() end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
  end
  states = {}
end

function M.toggle()
  if enabled then
    M.disable()
    vim.notify "Reference counts disabled"
  else
    M.enable()
    vim.notify "Reference counts enabled"
  end
end

-- Force a full recount of the current buffer
function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  local s = states[bufnr]
  if s then s.tick = nil end
  refresh(bufnr)
end

function M.debug()
  local bufnr = vim.api.nvim_get_current_buf()
  local lang = buf_lang(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  local query = get_query(lang)
  local count = 0
  if ok and parser and query then
    local tree = parser:parse()[1]
    if tree then
      for _ in query:iter_captures(tree:root(), bufnr, 0, -1) do
        count = count + 1
      end
    end
  end
  local s = states[bufnr]
  vim.notify(table.concat({
    "lsp-ref-count debug:",
    "  enabled: " .. tostring(enabled),
    "  filetype: " .. vim.bo[bufnr].filetype,
    "  lang: " .. lang,
    "  LSP clients: " .. #vim.lsp.get_clients { bufnr = bufnr },
    "  large buffer: " .. tostring(vim.b[bufnr].large_buf == true),
    "  parser ok: " .. tostring(ok),
    "  query ok: " .. tostring(query ~= false),
    "  functions found (treesitter): " .. count,
    "  cached counts: " .. (s and s.counts and vim.tbl_count(s.counts) or 0),
    "  in-flight requests: " .. (s and #s.cancels or 0),
  }, "\n"))
end

return M

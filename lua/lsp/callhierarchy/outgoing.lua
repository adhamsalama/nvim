local C = require "lsp.callhierarchy.common"
local ts_node_at, ensure_attached = C.ts_node_at, C.ensure_attached
local text, lsp_range, fn_types, FUNCTION_KIND = C.text, C.lsp_range, C.fn_types, C.FUNCTION_KIND
local function orig_request(...) return C.request(...) end

local M = {}

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

M.request_outgoing = request_outgoing

return M

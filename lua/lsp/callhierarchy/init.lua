
local C = require "lsp.callhierarchy.common"
local names = require "lsp.callhierarchy.names"
local incoming = require "lsp.callhierarchy.incoming"
local FILE_KINDS, FUNCTION_KIND, rel_path = C.FILE_KINDS, C.FUNCTION_KIND, C.rel_path
local load_buf, ensure_attached = C.load_buf, C.ensure_attached
local enclosing_name, declaration_name_pos = names.enclosing_name, names.declaration_name_pos
local request_references, request_var_references = incoming.request_references, incoming.request_var_references
local request_outgoing = require("lsp.callhierarchy.outgoing").request_outgoing
local prepare_fallback = require("lsp.callhierarchy.prepare").prepare_fallback

local M = {}

function M.setup()
  local util = require "lspsaga.util"
  C.request = util.client_request
  local orig_request = C.request

  util.client_request = function(client, method, params, handler, ...)
    local item = type(params) == "table" and type(params.item) == "table" and params.item
    if method == "callHierarchy/incomingCalls" and item and type(handler) == "function" then
      if item.__ref_leaf then
        return vim.schedule(function() handler(nil, {}) end)
      end
      if item.__var then return request_var_references(client, item, handler) end
      if item.__ref_pos then return request_references(client, item, handler) end
    end
    if method == "callHierarchy/outgoingCalls" and item and type(handler) == "function" then
      if item.__var then
        return vim.schedule(function() handler(nil, {}) end)
      end
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
end

return M

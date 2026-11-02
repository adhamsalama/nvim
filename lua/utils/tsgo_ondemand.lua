-- On-demand tsgo features for files too big to run them buffer-wide:
--   * function_hints(): inlay hints for the function under the cursor only. tsgo honours the
--     request range, so one function costs milliseconds where the whole 19k-line file costs ~6s.
local M = {}

local ns = vim.api.nvim_create_namespace "tsgo_function_hints"
local anchor_ns = vim.api.nvim_create_namespace "tsgo_function_hints_anchor"

local function tsgo(bufnr) return vim.lsp.get_clients({ bufnr = bufnr, name = "tsc" })[1] end

---------------------------------------------------------------------------------------------------
-- Function inlay hints
---------------------------------------------------------------------------------------------------

local named_fn = { function_declaration = true, generator_function_declaration = true, method_definition = true }
local any_fn = vim.tbl_extend("force", named_fn, { arrow_function = true, function_expression = true })

-- The nearest named function/method around the cursor (so a callback inside a method still shows
-- the whole method); falls back to the nearest anonymous function.
local function enclosing_function(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, ignore_injections = true })
  if not ok then return end
  local fallback
  while node do
    local t = node:type()
    if named_fn[t] then return node end
    if any_fn[t] and not fallback then
      -- `const fn = () => {}` / `fn: function () {}` count as named
      local parent = node:parent()
      if parent and (parent:type() == "variable_declarator" or parent:type() == "pair") then return parent end
      fallback = node
    end
    node = node:parent()
  end
  return fallback
end

local state = {} -- bufnr -> { anchor = extmark id, autocmd = id, timer = uv_timer }

local function label_text(hint)
  local label = hint.label
  if type(label) ~= "string" then
    local parts = {}
    for _, part in ipairs(label) do
      parts[#parts + 1] = part.value
    end
    label = table.concat(parts)
  end
  return (hint.paddingLeft and " " or "") .. label .. (hint.paddingRight and " " or "")
end

local function render(bufnr)
  local s = state[bufnr]
  local client = tsgo(bufnr)
  if not s or not client then return end
  local anchor = vim.api.nvim_buf_get_extmark_by_id(bufnr, anchor_ns, s.anchor, {})
  local node = anchor[1] and enclosing_function(bufnr, anchor[1], anchor[2])
  if not node then return vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
  local srow, _, erow, ecol = node:range()
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = { start = { line = srow, character = 0 }, ["end"] = { line = erow, character = ecol } },
  }
  local changedtick = vim.b[bufnr].changedtick
  client:request("textDocument/inlayHint", params, function(err, hints)
    if err or not vim.api.nvim_buf_is_valid(bufnr) or not state[bufnr] then return end
    if vim.b[bufnr].changedtick ~= changedtick then return end -- stale; a newer refresh is coming
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, hint in ipairs(hints or {}) do
      local line, char = hint.position.line, hint.position.character
      if line >= srow and line <= erow then -- tsgo returns a few hints just outside the range
        local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        local col = vim.str_byteindex(text, client.offset_encoding, char, false)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, col, {
          virt_text = { { label_text(hint), "LspInlayHint" } },
          virt_text_pos = "inline",
          right_gravity = hint.kind ~= 1, -- type hints stick to the left, parameter hints to the right
        })
      end
    end
  end, bufnr)
end

local function clear_hints(bufnr)
  local s = state[bufnr]
  if not s then return end
  if s.timer then s.timer:stop() end
  pcall(vim.api.nvim_del_autocmd, s.autocmd)
  state[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, anchor_ns, 0, -1)
  end
end

--- Toggle inlay hints for the function under the cursor. Pressing it inside another function moves
--- the hints there; pressing it inside the same function turns them off.
function M.function_hints()
  local bufnr = vim.api.nvim_get_current_buf()
  if not tsgo(bufnr) then return vim.notify("tsgo is not attached", vim.log.levels.WARN) end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = enclosing_function(bufnr, cursor[1] - 1, cursor[2])
  if not node then return vim.notify("No function under the cursor", vim.log.levels.WARN) end

  local s = state[bufnr]
  if s then
    local a = vim.api.nvim_buf_get_extmark_by_id(bufnr, anchor_ns, s.anchor, {})
    local current = a[1] and enclosing_function(bufnr, a[1], a[2])
    clear_hints(bufnr)
    if current and current:id() == node:id() then return end
  end

  local srow, scol = node:range()
  s = { anchor = vim.api.nvim_buf_set_extmark(bufnr, anchor_ns, srow, scol, {}) }
  state[bufnr] = s
  s.autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufUnload" }, {
    buffer = bufnr,
    desc = "Refresh tsgo function hints",
    callback = function(args)
      if args.event == "BufUnload" then return clear_hints(bufnr) end
      s.timer = s.timer or vim.uv.new_timer()
      s.timer:stop()
      s.timer:start(300, 0, vim.schedule_wrap(function() render(bufnr) end))
    end,
  })
  render(bufnr)
end

return M

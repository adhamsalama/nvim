-- On-demand tsgo features for files too big to run them buffer-wide:
--   * function_hints(): inlay hints for the function under the cursor only. tsgo honours the
--     request range, so one function costs milliseconds where the whole 19k-line file costs ~6s.
--   * toggle_check(): per-file type checking via a `// @ts-check` line that lives in the buffer
--     only; it is stripped before every write and put back after, so it never reaches disk.
local M = {}

local ns = vim.api.nvim_create_namespace "tsgo_function_hints"
local anchor_ns = vim.api.nvim_create_namespace "tsgo_function_hints_anchor"
local CHECK_LINE = "// @ts-check"

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

---------------------------------------------------------------------------------------------------
-- Per-file type checking
---------------------------------------------------------------------------------------------------

local function has_check_line(bufnr) return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == CHECK_LINE end

local function set_check_line(bufnr, on)
  local modified = vim.bo[bufnr].modified
  if on then
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { CHECK_LINE })
  else
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
  end
  -- the line is never on disk, so it shouldn't make an unmodified buffer look modified
  vim.bo[bufnr].modified = modified
end

--- Toggle type checking for this file only (a buffer-only `// @ts-check`).
function M.toggle_check()
  local bufnr = vim.api.nvim_get_current_buf()
  if not tsgo(bufnr) then return vim.notify("tsgo is not attached", vim.log.levels.WARN) end
  if vim.b[bufnr].tsgo_check then
    if has_check_line(bufnr) then set_check_line(bufnr, false) end
    vim.b[bufnr].tsgo_check = false
    return vim.notify "Type checking off (file)"
  end
  if has_check_line(bufnr) then return vim.notify "File already has // @ts-check" end
  set_check_line(bufnr, true)
  vim.b[bufnr].tsgo_check = true
  vim.notify "Type checking on (file)"

  if vim.b[bufnr].tsgo_check_autocmds then return end
  vim.b[bufnr].tsgo_check_autocmds = true
  local group = vim.api.nvim_create_augroup("tsgo_check_" .. bufnr, { clear = true })
  -- keep the line out of the file: drop it before the write, restore it after
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- only ever set the flag here: conform's re-write after an async format runs while the line
      -- is already out, and must not forget that it has to come back
      if vim.b[bufnr].tsgo_check and has_check_line(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
        vim.b[bufnr].tsgo_check_stripped = true
      end
    end,
  })
  local function restore()
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].tsgo_check_stripped then return end
    vim.b[bufnr].tsgo_check_stripped = false
    if has_check_line(bufnr) then return end
    local modified = vim.bo[bufnr].modified
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { CHECK_LINE })
    vim.bo[bufnr].modified = modified
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- conform formats large files asynchronously after the write and discards its result if the
      -- buffer changed meanwhile, so wait for it rather than re-inserting the line straight away
      if not vim.b[bufnr].tsgo_check_conform_pending then restore() end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ConformFormatPre",
    callback = function(args)
      if args.buf == bufnr then vim.b[bufnr].tsgo_check_conform_pending = true end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ConformFormatPost",
    callback = function()
      -- (fires from the job callback, so the current buffer may be any buffer)
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].tsgo_check_conform_pending then return end
      vim.b[bufnr].tsgo_check_conform_pending = false
      vim.schedule(restore) -- after conform applies the edits and re-writes the file
    end,
  })
end

return M

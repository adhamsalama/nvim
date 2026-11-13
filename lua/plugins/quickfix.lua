local function quickfix_history()
  local total = vim.fn.getqflist({ nr = "$" }).nr
  local current = vim.fn.getqflist({ nr = 0 }).nr
  local items = {}
  for i = 1, total do
    local list = vim.fn.getqflist { nr = i, title = 0, size = 0, items = 0 }
    local first = list.items and list.items[1]
    local file = first and first.bufnr > 0 and vim.api.nvim_buf_get_name(first.bufnr) or nil
    local hint = file and vim.fn.fnamemodify(file, ":.") or ""
    table.insert(items, {
      nr = i,
      current = i == current,
      title = list.title,
      size = list.size,
      hint = hint,
      text = list.title .. " " .. hint,
      file = file ~= "" and file or nil,
      pos = first and { math.max(first.lnum, 1), math.max(first.col - 1, 0) } or nil,
    })
  end
  if vim.tbl_isempty(items) then
    vim.notify("No quickfix lists", vim.log.levels.WARN)
    return
  end

  require("snacks").picker.pick {
    source = "quickfix_history",
    title = "Quickfix History",
    items = items,
    sort = { fields = { "nr:desc" } },
    format = function(item)
      return {
        { ("[%d]"):format(item.nr), "Number" },
        { item.current and " * " or "   ", "Special" },
        { item.title, "SnacksPickerLabel" },
        { (" (%d items)  "):format(item.size), "Comment" },
        { item.hint, "SnacksPickerFile" },
      }
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      local delta = item.nr - vim.fn.getqflist({ nr = 0 }).nr
      if delta > 0 then
        vim.cmd("silent cnewer " .. delta)
      elseif delta < 0 then
        vim.cmd("silent colder " .. -delta)
      end
      vim.cmd "copen"
    end,
  }
end

return {
  "AstroNvim/astrocore",
  opts = {
    mappings = {
      n = {
        ["<Leader>fq"] = { quickfix_history, desc = "Quickfix history picker" },
      },
    },
  },
}

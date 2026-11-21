-- The dashboard's `s` key loads the global "Last Session" (<Leader>Sl); load the working directory's session instead.
---@type LazySpec
return {
  "folke/snacks.nvim",
  opts = function(_, opts)
    local keys = vim.tbl_get(opts, "dashboard", "preset", "keys") or {}
    for _, key in ipairs(keys) do
      if key.key == "s" then
        key.action = "<Leader>S."
        key.desc = "Directory Session  "
      end
    end
  end,
}

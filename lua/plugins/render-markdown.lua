---@type LazySpec
return {
  "MeanderingProgrammer/render-markdown.nvim",
  ---@module 'render-markdown'
  ---@type render.md.UserConfig
  opts = {
    -- LSP hover/signature floats are markdown `nofile` buffers; leave them to polish.lua's conceal tweak
    overrides = { buftype = { nofile = { enabled = false } } },
  },
}
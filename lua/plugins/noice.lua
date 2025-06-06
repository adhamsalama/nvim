return {
  "folke/noice.nvim",
  event = "VeryLazy",
  opts = {
    cmdline = {
      enabled = true,
    },
    lsp = {
      progress = { enabled = false },
      message = { enabled = false },
      hover = { enabled = false },
      signature = { enabled = false },
      override = {},
    },
    messages = {
      enabled = false,
    },
    notify = {
      enabled = false,
    },
    popupmenu = {
      enabled = false,
    },
    presets = {},
  },
}

return {
  "rcarriga/nvim-dap-ui",
  opts = function(_, opts)
    opts.layouts = {
      {
        elements = {
          { id = "scopes", size = 0.70 },
          { id = "stacks", size = 0.20 },
          { id = "breakpoints", size = 0.05 },
          { id = "watches", size = 0.05 },
        },
        position = "right",
        size = 20,
      },
      {
        elements = {
          { id = "repl", size = 0.75 },
          { id = "console", size = 0.25 },
        },
        position = "bottom", -- Keep REPL & Console at the bottom
        size = 5,
      },
    }
    return opts
  end,
}

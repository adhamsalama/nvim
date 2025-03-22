return {
  "rcarriga/nvim-dap-ui",
  opts = function(_, opts)
    opts.layouts = {
      {
        elements = {
          { id = "scopes", size = 0.25 },
          { id = "breakpoints", size = 0.25 },
          { id = "stacks", size = 0.25 },
          { id = "watches", size = 0.25 },
        },
        position = "right",
        size = 40,
      },
      {
        elements = {
          { id = "repl", size = 0.75 },
          { id = "console", size = 0.25 },
        },
        position = "bottom", -- Keep REPL & Console at the bottom
        size = 10,
      },
    }
    return opts
  end,
}

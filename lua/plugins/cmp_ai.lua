return {
  {
    "Saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      if not opts.keymap then opts.keymap = {} end
      opts.keymap["<Tab>"] = {
        "snippet_forward",
        function()
          if vim.g.ai_accept then return vim.g.ai_accept() end
        end,
        "fallback",
      }
      opts.keymap["<S-Tab>"] = { "snippet_backward", "fallback" }
    end,
  },
  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    build = ":Copilot auth",
    event = "BufReadPost",
    opts = {
      suggestion = {
        enabled = true,
        auto_trigger = true, -- automatically show suggestions while typing
        keymap = {
          accept = false, -- handled by ai_accept
          next = false, -- don't use keys that conflict with Escape
          prev = false, -- same
        },
      },
      filetypes = {
        ["*"] = function()
          return not vim.fn.expand("%:t"):match("^%.env")
        end,
      },
    },
    specs = {
      {
        "AstroNvim/astrocore",
        opts = {
          options = {
            g = {
              -- ai_accept is called via AstroNvim's keymaps
              ai_accept = function()
                if require("copilot.suggestion").is_visible() then
                  require("copilot.suggestion").accept()
                  return true
                end
              end,
            },
          },
        },
      },
    },
  },
}

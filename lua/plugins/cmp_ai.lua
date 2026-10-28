return {
  {
    "Saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      if not opts.keymap then opts.keymap = {} end
      opts.keymap["<Tab>"] = {
        "snippet_forward",
        function()
          -- Claude ghost text (lua/plugins/claude-ghost.lua) when it's on, otherwise Copilot's via ai_accept
          if require("utils.claude_ghost").accept() then return true end
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
      -- `filetypes` functions get no bufnr (they'd read whatever buffer is current), so per-buffer checks live here
      should_attach = function(bufnr, bufname)
        if not vim.bo[bufnr].buflisted or vim.bo[bufnr].buftype ~= "" then return false end
        if vim.fs.basename(bufname):match "^%.env" then return false end
        -- skip huge files: with Copilot attached, tsc's memory climbs past 12GB on them
        if vim.api.nvim_buf_line_count(bufnr) > 5000 then return false end
        return true
      end,
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

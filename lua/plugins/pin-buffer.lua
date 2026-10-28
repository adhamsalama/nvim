-- Pin the current buffer to the left of the tabline. Logic lives in
-- `lua/utils/pin_buffer.lua`; this file wires it into AstroNvim and resession.

---@type LazySpec
return {
  -- Keymap + autocmds (attach to astrocore so its mappings/autocmds API is used)
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local pin = require "utils.pin_buffer"

      opts.mappings = opts.mappings or {}
      opts.mappings.n = opts.mappings.n or {}
      opts.mappings.n["<Leader>bp"] = {
        function() pin.toggle() end,
        desc = "Pin/unpin buffer (keep left)",
      }

      opts.autocmds = opts.autocmds or {}
      opts.autocmds.pin_buffer = {
        {
          -- Re-sort pinned buffers to the front whenever the tabline's buffer
          -- list changes (new file opened, buffer closed, etc.).
          event = "User",
          pattern = "AstroBufsUpdated",
          desc = "Keep pinned buffers at the left of the tabline",
          callback = function() require("utils.pin_buffer").reorder() end,
        },
      }
    end,
  },

  -- Persist pins in sessions via `lua/resession/extensions/pin_buffer.lua`.
  {
    "stevearc/resession.nvim",
    optional = true,
    opts = function(_, opts)
      opts.extensions = opts.extensions or {}
      opts.extensions.pin_buffer = { enable_in_tab = true }
    end,
  },

  -- Show a pin icon on pinned tabs. Index 2 of the tabline is the buffer list;
  -- we rebuild just that element to prefix each pinned buffer with a glyph.
  {
    "rebelot/heirline.nvim",
    optional = true,
    opts = function(_, opts)
      if not opts.tabline then return end
      local status = require "astroui.status"
      opts.tabline[2] = status.heirline.make_buflist {
        {
          condition = function(self) return require("utils.pin_buffer").is_pinned(self.bufnr) end,
          provider = "󰐃 ",
          hl = { fg = "orange" },
        },
        status.component.tabline_file_info(),
      }
    end,
  },
}

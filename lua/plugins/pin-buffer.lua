-- Pin the current buffer to the left of the tabline. Logic lives in
-- `lua/utils/pin_buffer.lua`; this file wires it into AstroNvim.

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
        {
          -- Load this cwd's saved pins on startup.
          event = "VimEnter",
          desc = "Load persisted buffer pins",
          callback = function() require("utils.pin_buffer").refresh() end,
        },
        {
          -- Sessions restore a different set of buffers (and possibly cwd), so
          -- reload the matching pins and re-sort once the session is in.
          event = "User",
          pattern = "ResessionLoadPost",
          desc = "Restore buffer pins after loading a session",
          callback = function() require("utils.pin_buffer").refresh() end,
        },
        {
          -- Pins are scoped per working directory; reload them on a global cd.
          event = "DirChanged",
          pattern = "global",
          desc = "Reload buffer pins when the working directory changes",
          callback = function() require("utils.pin_buffer").refresh() end,
        },
      }
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

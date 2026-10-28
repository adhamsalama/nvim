-- Copilot-style ghost text from Claude, informed by the Claude Code session in this cwd. Logic lives in
-- `lua/utils/claude_ghost.lua`; this file wires it into AstroNvim. Tab accepts through vim.g.ai_accept,
-- which `lua/plugins/cmp_ai.lua` calls from blink.cmp's Tab mapping.

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local function ghost() return require "utils.claude_ghost" end

      opts.mappings = opts.mappings or {}
      opts.mappings.i = opts.mappings.i or {}
      opts.mappings.i["<M-\\>"] = { function() ghost().trigger() end, desc = "Claude ghost text now" }
      opts.mappings.n = opts.mappings.n or {}
      opts.mappings.n["<Leader>ag"] = {
        function()
          ghost().toggle()
          -- One ghost text at a time: pause Copilot while Claude's is on.
          pcall(vim.cmd.Copilot, vim.g.claude_ghost_enabled and "disable" or "enable")
        end,
        desc = "Toggle Claude ghost text (instead of Copilot)",
      }

      opts.autocmds = opts.autocmds or {}
      opts.autocmds.claude_ghost = {
        {
          event = "TextChangedI",
          desc = "Update Claude ghost text after typing",
          callback = function() ghost().on_text_changed() end,
        },
        {
          event = "CursorMovedI",
          desc = "Drop Claude ghost text when the cursor moves away",
          callback = function() ghost().on_cursor_moved() end,
        },
        {
          event = "InsertEnter",
          desc = "Request Claude ghost text on entering insert mode",
          callback = function() ghost().on_insert_enter() end,
        },
        {
          event = { "InsertLeave", "BufLeave" },
          desc = "Clear Claude ghost text",
          callback = function() ghost().on_insert_leave() end,
        },
      }
    end,
  },
}

-- Name tab pages. The name is stored in the tab-local `vim.t.name` and shown in
-- the tabline's tab list in place of the tab number (unnamed tabs keep their number).

---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      opts.mappings = opts.mappings or {}
      opts.mappings.n = opts.mappings.n or {}
      opts.mappings.n["<Leader>btr"] = {
        function()
          vim.ui.input({ prompt = "Tab name: ", default = vim.t.name }, function(name)
            if name == nil then return end -- cancelled
            vim.t.name = name ~= "" and name or nil -- empty input clears the name
            vim.cmd.redrawtabline()
          end)
        end,
        desc = "Rename tab",
      }

      -- Keep plugin tabs (by name) to the right of regular tabs: a new plugin tab
      -- moves to the end, and a new regular tab moves in front of the plugin tabs.
      local plugin_tabs = { GitGraph = true, DB = true, kubectl = true }
      opts.autocmds = opts.autocmds or {}
      opts.autocmds.plugin_tabs_right = {
        {
          event = "TabNew",
          desc = "Keep plugin tabs to the right",
          callback = function()
            -- plugins name their tab right after `tabnew`, so check once that's done
            local tab = vim.api.nvim_get_current_tabpage()
            vim.schedule(function()
              -- `tabmove` acts on the current tab; skip if focus moved on (e.g. session restore)
              if tab ~= vim.api.nvim_get_current_tabpage() then return end
              if plugin_tabs[vim.t[tab].name] then
                vim.cmd "tabmove $"
              else
                local nr = vim.api.nvim_tabpage_get_number(tab)
                for i, t in ipairs(vim.api.nvim_list_tabpages()) do
                  if i >= nr then break end
                  if plugin_tabs[vim.t[t].name] then
                    vim.cmd("tabmove " .. (i - 1))
                    break
                  end
                end
              end
            end)
          end,
        },
      }
    end,
  },

  -- Persist tab names in sessions via `lua/resession/extensions/tab_names.lua`.
  {
    "stevearc/resession.nvim",
    optional = true,
    opts = function(_, opts)
      opts.extensions = opts.extensions or {}
      opts.extensions.tab_names = { enable_in_tab = true }
    end,
  },

  -- Index 4 of AstroNvim's tabline is the tab list; rebuild its per-tab component
  -- (same as AstroNvim's) with a label that prefers the tab name over the number.
  {
    "rebelot/heirline.nvim",
    optional = true,
    opts = function(_, opts)
      local tablist = opts.tabline and opts.tabline[4]
      if not tablist then return end
      local status = require "astroui.status"
      tablist[1] = status.heirline.make_tablist {
        provider = function(self)
          local label = vim.t[self.tabpage].name or self.tabnr
          return "%" .. self.tabnr .. "T " .. label .. " %T"
        end,
        hl = function(self) return status.hl.get_attributes(status.heirline.tab_type(self, "tab"), true) end,
      }
    end,
  },
}

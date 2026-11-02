-- kubectl.nvim's header float (hints/version/context) can leak into other tabs:
-- its CursorHold autocmd is global, and when the header window is gone it reopens
-- the float in whichever tab is current. Floats are tab-local, so it stays there.
local function patch_header()
  local header = require "kubectl.views.header"
  local manager = require "kubectl.resource_manager"

  local function in_k8s_buf() return vim.bo.filetype:match "^k8s_" ~= nil end

  local draw, hide = header.Draw, header.Hide
  -- The autocmds call M.Draw()/M.Hide() through the module table, so overriding works.
  header.Draw = function(...)
    if not in_k8s_buf() then return end
    local builder = manager.get "header"
    local win = builder and builder.win_nr
    -- A header float stranded in another tab: close it so it's recreated here.
    if
      win
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
    then
      pcall(vim.api.nvim_win_close, win, true)
      builder.win_nr = nil
    end
    return draw(...)
  end
  header.Hide = function(...)
    if in_k8s_buf() then return hide(...) end
  end
end

-- Closing the kubectl tab without the toggle (:tabclose, :q) leaves the plugin
-- "open" with its header state and autocmds alive. Shut it down properly.
local function close_when_tab_gone()
  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("kubectl_tab_closed", { clear = true }),
    desc = "Close kubectl when its last window is gone",
    callback = vim.schedule_wrap(function()
      local kubectl = require "kubectl"
      if not kubectl.is_open then return end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype:match "^k8s_" and vim.api.nvim_win_get_config(win).relative == "" then return end
      end
      kubectl.close()
      kubectl.is_open = false
    end),
  })
end

return {
  {
    "ramilito/kubectl.nvim",
    version = "2.43.1",
    dependencies = "saghen/blink.download",
    config = function()
      require("kubectl").setup()
      patch_header()
      close_when_tab_gone()
    end,
    keys = {
      {
        "<leader>tk",
        function()
          local kubectl = require "kubectl"
          local opening = not kubectl.is_open
          kubectl.toggle { tab = true }
          -- toggle opens the new tab synchronously, so it's current here
          if opening then
            vim.t.name = "kubectl"
            vim.cmd.redrawtabline()
          end
        end,
        desc = "Toggle kubectl UI",
        mode = "n",
      },
    },
  },
}

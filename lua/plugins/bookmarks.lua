-- Bookmarks: LintaoAmons/bookmarks.nvim, stored in a SQLite database (stdpath("data")/bookmarks.sqlite.db). Each
-- bookmark keeps its line's text, and on entering a buffer the plugin finds that text in the file again, so bookmarks
-- follow lines that a `git pull` moved. A bookmark on a line whose text changed, or whose text appears more than once,
-- can still land on the wrong line.
--
-- Bookmarks are per working directory, like vim-bookmarks' were: the directory's list (named after it, relative to
-- $HOME) is made the active list on start, on :cd and on focus. The active list lives in the shared database, so with
-- two Neovims in different directories, focus decides which one's list is active.
--
-- vim-bookmarks' `.vim-bookmarks` files were left in their directories (its bookmarks were copied over).

---Name of the bookmark list for a directory: its path relative to $HOME.
---@param dir string
local function list_name(dir) return (dir:gsub("^" .. vim.pesc(vim.env.HOME) .. "/", "")) end

-- Make the working directory's list the active one, creating it the first time.
local function activate_cwd_list()
  local Repo = require "bookmarks.domain.repo"
  local Service = require "bookmarks.domain.service"
  local name = list_name(vim.fn.getcwd())
  if Repo.ensure_and_get_active_list().name == name then return end
  local list
  for _, l in ipairs(Repo.find_lists()) do
    if l.name == name then
      list = l
      break
    end
  end
  if list then
    Service.set_active_list(list.id)
  else
    Service.create_list(name) -- also makes it active
  end
  require("bookmarks.sign").safe_refresh_signs()
end

-- Picks a bookmark of the active list. The plugin's own picker (:BookmarksGoto) shows only the file and line, so this
-- one also shows each bookmark's name and its line's text (as it was when marked).
local function pick_bookmark()
  local Repo, Node = require "bookmarks.domain.repo", require "bookmarks.domain.node"
  local Service, Sign = require "bookmarks.domain.service", require "bookmarks.sign"
  local list = Repo.ensure_and_get_active_list()
  local items = {}
  for _, b in ipairs(Node.get_all_bookmarks(list)) do
    local text = b.content or ""
    if text == "" and vim.fn.filereadable(b.location.path) == 1 then -- not stored (see sql_safe): the line now
      text = vim.fn.readfile(b.location.path, "", b.location.line)[b.location.line] or ""
    end
    text = vim.trim(text)
    table.insert(items, {
      text = b.name .. " " .. b.location.path .. " " .. text, -- what the search matches
      file = b.location.path,
      pos = { b.location.line, b.location.col or 0 },
      line = text,
      bookmark = b,
    })
  end
  local file_format = require("snacks.picker.format").file
  require("snacks").picker.pick {
    title = "Bookmarks in [" .. list.name .. "]",
    items = items,
    format = function(item, picker)
      local ret = {}
      if item.bookmark.name ~= "" then ret = { { item.bookmark.name, "SnacksPickerLabel" }, { "  " } } end
      local file = file_format(item, picker)
      -- The line text's syntax highlights (extmarks) have columns counted from the start of `file`: shift them past
      -- the name in front.
      local shift = #item.bookmark.name > 0 and #item.bookmark.name + 2 or 0
      for _, part in ipairs(file) do
        if part.col then
          part.col, part.end_col = part.col + shift, part.end_col and part.end_col + shift
        end
      end
      return vim.list_extend(ret, file)
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      Service.goto_bookmark(item.bookmark.id)
      Sign.safe_refresh_signs()
    end,
    actions = {
      delete_bookmark = function(picker, item)
        if not item then return end
        Service.delete_node(item.bookmark.id)
        Sign.safe_refresh_signs()
        picker:close()
        vim.schedule(pick_bookmark)
      end,
    },
    win = { input = { keys = { ["<C-d>"] = { "delete_bookmark", mode = { "i", "n" }, desc = "Delete bookmark" } } } },
  }
end

-- sqlite.lua runs a text value shaped like `name(...)` as SQL instead of storing it (its `^[%S]+%(.*%)$` check), so
-- bookmarking an unindented line like `main(int argc, char *argv[])` fails. Such a line's text isn't stored (the
-- bookmark then keeps its line number, as vim-bookmarks did), and a trailing space keeps a name or description out.
local function sql_safe()
  local Repo = require "bookmarks.domain.repo"
  local function is_sql(v) return type(v) == "string" and v:match "^[%S]+%(.*%)$" ~= nil end
  for _, fn in ipairs { "insert_node", "insert_node_at_position", "update_node" } do
    local orig = Repo[fn]
    Repo[fn] = function(node, ...)
      if is_sql(node.content) then node.content = "" end
      if is_sql(node.name) then node.name = node.name .. " " end
      if is_sql(node.description) then node.description = node.description .. " " end
      return orig(node, ...)
    end
  end
end

-- bookmarks.nvim draws a bookmark's name with virt_text_pos = "overlay" past the end of its line, which paints over
-- gitsigns' line blame there (virt_text_pos = "eol"). Same `place_sign` (sign.lua), with the name right-aligned. Its
-- sign refresh calls it through the module table, so this replaces it everywhere.
-- NOTE: this is a copy of the plugin's function, so a plugin update that changes `place_sign` is silently ignored
-- here. After updating bookmarks.nvim, compare its sign.lua with this copy. Drop this once the plugin has an option
-- for the name's position.
local function right_align_names()
  local Sign = require "bookmarks.sign"
  local ns = vim.api.nvim_create_namespace "BookmarksNvim" -- the plugin's namespace (returns the existing one)
  Sign.place_sign = function(line, buf, desc)
    vim.fn.sign_place(line, "BookmarksNvim", "BookmarksNvimSign", buf, { lnum = line })
    local row = line - 1
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { desc, "BookmarksNvimSign" } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
    local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_row = row, end_col = #text, hl_group = "BookmarksNvimLine" })
  end
end

-- Colors from the colorscheme instead of the plugin's fixed red (signs.mark.color / line_bg, turned off in opts): the
-- icon and name take DiagnosticInfo's color, and a bookmarked line gets that color blended faintly into the background.
local function theme_highlights()
  local function get(group, attr) return vim.api.nvim_get_hl(0, { name = group, link = false })[attr] end
  local accent = get("DiagnosticInfo", "fg") or get("Special", "fg")
  local bg = get("Normal", "bg")
  vim.api.nvim_set_hl(0, "BookmarksNvimSign", { fg = accent })
  if not (accent and bg) then return vim.api.nvim_set_hl(0, "BookmarksNvimLine", { link = "CursorLine" }) end
  local alpha, blended = 0.15, 0
  for shift = 16, 0, -8 do -- per channel: alpha * accent + (1 - alpha) * bg
    local a, b = bit.band(bit.rshift(accent, shift), 0xff), bit.band(bit.rshift(bg, shift), 0xff)
    blended = blended + bit.lshift(math.floor(alpha * a + (1 - alpha) * b + 0.5), shift)
  end
  vim.api.nvim_set_hl(0, "BookmarksNvimLine", { bg = blended })
end

return {
  {
    "LintaoAmons/bookmarks.nvim",
    branch = "main", -- the latest tag (v4.0.0) still requires telescope for its picker; main uses snacks
    dependencies = {
      "kkharji/sqlite.lua",
      "folke/snacks.nvim",
      {
        "AstroNvim/astrocore",
        opts = {
          mappings = {
            n = {
              ["<Leader>m"] = { name = "Bookmarks" },
              ["<Leader>mm"] = {
                function()
                  -- no name prompt: an empty name adds a bookmark, or removes the one on this line
                  require("bookmarks.domain.service").toggle_mark ""
                  require("bookmarks.sign").safe_refresh_signs()
                end,
                desc = "Toggle Bookmark",
              },
              ["<Leader>ma"] = { "<Cmd>BookmarksMark<CR>", desc = "Name Bookmark (empty removes it)" },
              ["<Leader>ml"] = { pick_bookmark, desc = "List Bookmarks" },
              ["<Leader>mn"] = { "<Cmd>BookmarksGotoNext<CR>", desc = "Next Bookmark" },
              ["<Leader>mp"] = { "<Cmd>BookmarksGotoPrev<CR>", desc = "Previous Bookmark" },
              ["<Leader>mc"] = {
                function() require("bookmarks.commands")["Delete marks of current file"]() end,
                desc = "Clear Bookmarks",
              },
              ["<Leader>mt"] = { "<Cmd>BookmarksTree<CR>", desc = "Bookmarks Tree" },
            },
          },
        },
      },
    },
    event = "VeryLazy",
    opts = { signs = { mark = { color = false, line_bg = false } } }, -- colors: theme_highlights
    config = function(_, opts)
      require("bookmarks").setup(opts)
      sql_safe()
      theme_highlights()
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("BookmarksThemeColors", { clear = true }),
        callback = theme_highlights,
        desc = "Bookmark colors from the colorscheme",
      })
      right_align_names()
      activate_cwd_list()
      vim.api.nvim_create_autocmd({ "DirChanged", "FocusGained" }, {
        group = vim.api.nvim_create_augroup("BookmarksCwdList", { clear = true }),
        callback = function() activate_cwd_list() end,
        desc = "Activate the working directory's bookmark list",
      })
    end,
  },

  -- The dashboard's Bookmarks key (') opens AstroNvim's marks picker (<Leader>f'); pick from these bookmarks instead.
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local keys = vim.tbl_get(opts, "dashboard", "preset", "keys") or {}
      for _, key in ipairs(keys) do
        if key.key == "'" then key.action = pick_bookmark end
      end
    end,
  },
}

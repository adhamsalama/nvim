return {
  "nvim-telescope/telescope.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    local telescope = require "telescope"
    local pickers = require "telescope.pickers"
    local finders = require "telescope.finders"
    local conf = require("telescope.config").values
    local builtin = require "telescope.builtin"

    telescope.setup {}

    vim.api.nvim_create_user_command(
      "TelescopeFunctionsOnly",
      function()
        builtin.lsp_workspace_symbols {
          symbols = { "Function", "Method" },
        }
      end,
      {}
    )

    vim.api.nvim_create_user_command("TelescopeBufferFunctionsOnly", function()
      vim.lsp.buf_request(
        0,
        "textDocument/documentSymbol",
        { textDocument = vim.lsp.util.make_text_document_params() },
        function(err, result, _, _)
          if err or not result then return end

          local function flatten_symbols(symbols, flattened)
            flattened = flattened or {}
            for _, symbol in ipairs(symbols) do
              table.insert(flattened, symbol)
              if symbol.children then flatten_symbols(symbol.children, flattened) end
            end
            return flattened
          end

          local symbols = flatten_symbols(result)

          local filtered_symbols = {}
          for _, symbol in ipairs(symbols) do
            if
              (symbol.kind == 12 or symbol.kind == 6)
              and symbol.name
              and symbol.name ~= ""
              and not symbol.name:match "^anonymous" -- skip names starting with anonymous
              and not symbol.name:match "%(%) callback$" -- skip names ending with "() callback"
            then
              table.insert(filtered_symbols, symbol)
            end
          end

          pickers
            .new({}, {
              prompt_title = "Functions/Methods",
              finder = finders.new_table {
                results = filtered_symbols,
                entry_maker = function(entry)
                  local kind_name = (entry.kind == 12 and "Function") or (entry.kind == 6 and "Method") or "Unknown"
                  return {
                    value = entry,
                    display = string.format("%s (%s)", entry.name, kind_name),
                    ordinal = entry.name,
                    lnum = entry.range.start.line + 1,
                    col = entry.range.start.character + 1,
                    filename = vim.api.nvim_buf_get_name(0),
                  }
                end,
              },
              previewer = conf.grep_previewer {},
              sorter = conf.generic_sorter {},
              attach_mappings = function(_, map)
                local actions = require "telescope.actions"
                local action_state = require "telescope.actions.state"
                map("i", "<CR>", function(prompt_bufnr)
                  local selection = action_state.get_selected_entry()
                  actions.close(prompt_bufnr)
                  vim.api.nvim_win_set_cursor(0, { selection.lnum, selection.col - 1 })
                end)
                return true
              end,
            })
            :find()
        end
      )
    end, {})
  end,

  keys = {
    -- { "<leader>lF", "<cmd>TelescopeFunctionsOnly<cr>", desc = "LSP Workspace Functions" },
    { "<leader>lF", "<cmd>TelescopeBufferFunctionsOnly<cr>", desc = "LSP Buffer Functions (Named)" },
  },
}

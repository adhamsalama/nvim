-- fzf.vim restores the window layout with winrestcmd() when fzf exits, and Neovim's winrestcmd() also covers floating
-- windows, addressed by window number. Floats get reordered while bqf's `zf` filter is open, so the preview's size is
-- replayed onto its 1-column scrollbar float, which then paints over the preview and the quickfix list. Rebuild the
-- preview once fzf.vim is done restoring.
return {
  "kevinhwang91/nvim-bqf",
  init = function()
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("bqf_fzf_restore_preview", { clear = true }),
      pattern = "fzf",
      callback = function(args)
        local qwinid = vim.fn.win_getid(vim.fn.winnr "#")
        local wintype = vim.fn.win_gettype(qwinid)
        if wintype ~= "quickfix" and wintype ~= "loclist" then return end
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = args.buf,
          once = true,
          callback = function()
            -- Deferred past fzf.vim's on_exit, which runs the winrestcmd() after wiping this buffer
            vim.schedule(function()
              if vim.api.nvim_get_current_win() == qwinid then require("bqf.preview.handler").redrawWin(qwinid) end
            end)
          end,
        })
      end,
    })
  end,
}

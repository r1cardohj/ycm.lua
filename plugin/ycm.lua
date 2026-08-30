-- 入口:对照 YouCompleteMe 的 plugin/youcompleteme.vim,
-- VimEnter 后以默认配置启用;若用户在 init.lua 中自行 setup() 则跳过。
if vim.g.loaded_ycm_lua then
  return
end
vim.g.loaded_ycm_lua = true

vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    if not require('ycm')._setup_done then
      require('ycm').setup()
    end
  end,
})

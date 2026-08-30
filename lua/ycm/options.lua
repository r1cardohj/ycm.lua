-- 对应 YouCompleteMe 的 g:ycm_* 选项(见 plugin/youcompleteme.vim)
local M = {}

M.defaults = {
  -- 触发
  auto_trigger = true,                    -- g:ycm_auto_trigger
  min_num_of_chars_for_completion = 2,    -- g:ycm_min_num_of_chars_for_completion
  min_num_identifier_candidate_chars = 0, -- g:ycm_min_num_identifier_candidate_chars
  max_num_candidates = 50,                -- g:ycm_max_num_candidates
  max_num_identifier_candidates = 10,     -- g:ycm_max_num_identifier_candidates

  -- 行为
  complete_in_comments = false,           -- g:ycm_complete_in_comments
  complete_in_strings = true,             -- g:ycm_complete_in_strings
  collect_identifiers_from_comments_and_strings = false,
  -- 用 treesitter highlights 查询中的字面量播种语言关键字
  -- (现代版 g:ycm_seed_identifiers_with_syntax;无 parser 时静默跳过)
  seed_identifiers_with_syntax = true,
  signature_help = true,

  -- filetype 白/黑名单(与 YCM 默认一致)
  filetype_whitelist = { ['*'] = true },
  filetype_blacklist = {
    tagbar = 1, notes = 1, markdown = 1, netrw = 1, unite = 1,
    text = 1, vimwiki = 1, pandoc = 1, infolog = 1, leaderf = 1,
    mail = 1, ycm_nofiletype = 1,
  },
  buftype_blacklist = {
    help = 1, terminal = 1, quickfix = 1, prompt = 1, nofile = 1,
  },
  disable_for_files_larger_than_kb = 1000, -- g:ycm_disable_for_files_larger_than_kb

  -- 键位(与 YCM 默认一致)
  key_list_select_completion = { '<TAB>', '<Down>' },
  key_list_previous_completion = { '<S-TAB>', '<Up>' },
  key_list_stop_completion = { '<C-y>' },
  key_invoke_completion = '<C-Space>',

  -- 语义触发(对照 ycmd completer_utils.py 的 DEFAULT_FILETYPE_TRIGGERS,
  -- 用户可通过 semantic_triggers 按 filetype 覆盖,支持 're!' 前缀,使用 Vim 正则)
  semantic_triggers = {},

  -- 数据源
  use_lsp = true,                -- LSP 语义补全(对应 YCM 的 ycmd semantic completer)
  lsp_merge_mode = 'exclusive',  -- 'exclusive': LSP 结果非空时排他(现行 YCM 行为)
                                 -- 'merge':     与 identifier 候选合并
  use_filepath_completion = true,
  filepath_blacklist = { html = 1, jsx = 1, xml = 1 }, -- g:ycm_filepath_blacklist
  filepath_completion_use_working_dir = false,

  -- LSP snippet 展开(需要 Neovim >= 0.10 的 vim.snippet;YCM 原生不做,默认关)
  lsp_snippet_expand = false,
}

M.values = vim.deepcopy(M.defaults)

function M.setup(user)
  M.values = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), user or {})
  return M.values
end

function M.get()
  return M.values
end

-- 对应 youcompleteme#filetypes#AllowedForFiletype
function M.allowed_for_filetype(ft)
  local v = M.values
  if ft == '' then
    ft = 'ycm_nofiletype'
  end
  if v.filetype_blacklist[ft] then
    return false
  end
  if not v.filetype_whitelist['*'] and not v.filetype_whitelist[ft] then
    return false
  end
  return true
end

return M

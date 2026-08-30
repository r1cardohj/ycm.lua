-- 主编排模块,对照 autoload/youcompleteme.vim 的触发/渲染流程:
--   TextChangedI/TextChangedP -> 计算 query -> 收集候选 -> complete()
--   InsertCharPre 区分用户输入与 <C-n> 选择(TextChangedP 不重过滤)
--   complete() 时临时加 noselect,候选带 equal=1 关闭 Vim 侧过滤
local options = require('ycm.options')
local ident = require('ycm.ident')
local triggers = require('ycm.triggers')
local keys = require('ycm.keys')
local identifiers = require('ycm.sources.identifiers')
local lsp = require('ycm.sources.lsp')
local path = require('ycm.sources.path')

local M = {}
M._setup_done = false

local AUGROUP = vim.api.nvim_create_augroup('YcmLua', { clear = false })

-- 对应 autoload 中的 s: 脚本级状态
local state = {
  completion_stopped = false,      -- s:completion_stopped
  force_semantic = false,          -- s:force_semantic
  last_char_inserted_by_user = true, -- s:last_char_inserted_by_user
  request_id = 0,                  -- 递增 id,用于丢弃过期响应
  req_pos = nil,                   -- 请求发起时的 { row, col, buf }
  req_ctx = nil,                   -- 请求上下文(同步候选等,供 LSP 回调复用)
}

-- ---------------------------------------------------------------------------
-- buffer 准入(对照 s:AllowedToCompleteInBuffer / s:DisableOnLargeFile)
-- ---------------------------------------------------------------------------
function M.allowed_in_buffer(bufnr)
  local bt = vim.bo[bufnr].buftype
  if options.get().buftype_blacklist[bt] then
    return false
  end
  if not options.allowed_for_filetype(vim.bo[bufnr].filetype) then
    return false
  end
  local threshold = options.get().disable_for_files_larger_than_kb * 1024
  if threshold > 0 then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= '' then
      local size = vim.fn.getfsize(name)
      if size > threshold then
        return false
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- 注释/字符串检测(对照 s:InsideCommentOrString):treesitter 优先,syntax 兜底
-- ---------------------------------------------------------------------------
local function inside_comment_or_string()
  local ok, node = pcall(vim.treesitter.get_node, 0)
  if ok and node then
    while node do
      local t = node:type()
      if t:find('comment') then
        return 1
      end
      if t:find('string') then
        return 2
      end
      node = node:parent()
    end
    return 0
  end
  local col = vim.fn.col('.') - 1
  if col < 1 then
    return 0
  end
  local name = vim.fn.synIDattr(
    vim.fn.synIDtrans(vim.fn.synID(vim.fn.line('.'), col, 1)), 'name')
  if name:find('Comment') then
    return 1
  end
  if name:find('String') then
    return 2
  end
  return 0
end

-- 对照 s:InsideCommentOrStringAndShouldStop
local function inside_comment_or_string_and_should_stop()
  local ret = inside_comment_or_string()
  local opts = options.get()
  if (ret == 1 and opts.complete_in_comments)
      or (ret == 2 and opts.complete_in_strings) then
    return false
  end
  return ret ~= 0
end

-- ---------------------------------------------------------------------------
-- complete() 渲染(对照 s:Complete / s:CloseCompletionMenu)
-- ---------------------------------------------------------------------------

-- 对应 base.OverlapLength:候选末尾与光标后文本开头的重叠长度
local function overlap_length(left, right)
  local ll, rl = #left, #right
  if ll == 0 or rl == 0 then
    return 0
  end
  local n = math.min(ll, rl)
  for len = n, 1, -1 do
    if left:sub(ll - len + 1) == right:sub(1, len) then
      return len
    end
  end
  return 0
end

-- 对应 base.AdjustCandidateInsertionText:
-- 防止 "foo.|bar" 选 "zoobar" 后变成 "foo.zoobarbar"
local function adjust_insertion_text(items)
  local line, col = ident.current_line_and_col()
  local after = line:sub(col)
  if after == '' then
    return items
  end
  for _, item in ipairs(items) do
    local ov = overlap_length(item.word, after)
    if ov > 0 then
      if not item.abbr then
        item.abbr = item.word
      end
      item.word = item.word:sub(1, #item.word - ov)
    end
  end
  return items
end

local function send_keys(k)
  -- 对照 s:SendKeys:插入 typeahead 队首且不重新映射
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, true, true),
    'in', false)
end

local function close_completion_menu()
  if vim.fn.pumvisible() == 1 then
    send_keys('<C-e>')
  end
end

-- 真正调用 complete();必须异步(vim.schedule)调用,
-- 对照 YCM 的 timer_start(0, s:PollCompletion) 注释:
-- TextChangedI/TextChangedP 中不能同步调用 complete()
local function deliver(request_id, start_col, items)
  vim.schedule(function()
    if request_id ~= state.request_id then
      return -- 已有更新的请求,过期响应丢弃
    end
    -- 对照 s:Complete 的 mode 检查;注意 Neovim 的 nvim_get_mode() 在补全
    -- 激活时返回 'ic'/'Rc'(Vim 的 mode() 不带参数只返回 'i'),故按前缀判断
    local mode = vim.api.nvim_get_mode().mode
    if mode:sub(1, 1) ~= 'i' and mode:sub(1, 1) ~= 'R' then
      return
    end
    -- 对照 s:PollCompletion 中的位置校验:光标已移动则丢弃
    local pos = state.req_pos
    local cur = vim.api.nvim_win_get_cursor(0)
    if not pos or cur[1] ~= pos.row or cur[2] ~= pos.col then
      return
    end
    if #items == 0 then
      close_completion_menu()
      return
    end

    items = adjust_insertion_text(items)

    -- 对照 s:SetUpCompleteopt + s:Complete:
    -- menuone 常驻,complete() 时加 noselect;去掉会破坏手感的选项
    local old = vim.o.completeopt
    local parts = {}
    for _, p in ipairs(vim.split(old, ',', { plain = true })) do
      if p ~= 'noselect' and p ~= 'fuzzy' and p ~= 'preinsert' and p ~= 'menu' then
        parts[#parts + 1] = p
      end
    end
    if not vim.tbl_contains(parts, 'menuone') then
      parts[#parts + 1] = 'menuone'
    end
    parts[#parts + 1] = 'noselect'
    vim.o.completeopt = table.concat(parts, ',')
    vim.fn.complete(start_col, items)
    vim.o.completeopt = old
  end)
end

-- ---------------------------------------------------------------------------
-- 补全请求(对照 s:RequestCompletion + ycmd 的 ComputeCandidates 流程)
-- ---------------------------------------------------------------------------
local function request_completion(force_semantic)
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  local opts = options.get()

  state.request_id = state.request_id + 1
  local id = state.request_id

  local start_col, query = ident.query_at_cursor(ft)
  local cur = vim.api.nvim_win_get_cursor(0)
  state.req_pos = { row = cur[1], col = cur[2], buf = bufnr }
  state.force_semantic = force_semantic or state.force_semantic

  local query_len_ok = ident.char_count(query) >=
    opts.min_num_of_chars_for_completion
  local line_before = vim.api.nvim_get_current_line():sub(1, cur[2])
  local triggered = triggers.matches(ft, line_before)

  -- 同步源(对照 IdentifierCompleter 的 ShouldUseNow:query 达最小长度)
  local sync_items = {}
  if query_len_ok then
    for _, w in ipairs(identifiers.collect(query, ft)) do
      sync_items[#sync_items + 1] = {
        word = w,
        abbr = w,
        menu = '[ID]',
        equal = 1,
        dup = 1,
        empty = 1,
      }
    end
  end
  -- 路径补全(YCM filepath completer,与 identifier 候选合并)
  local path_items, path_start = path.collect(bufnr, ft)
  if path_items then
    start_col = path_start
    sync_items = path_items
    query = query:match('[^%/]*$') or ''
  end

  state.req_ctx = { sync_items = sync_items, start_col = start_col, query = query }

  -- 对照 ycmd Completer.ShouldUseNow(Inner):语义补全的自动触发只看触发器
  -- (不看 query 长度!);触发后同一次补全会话内(同一行、同一 start_col)
  -- 继续用语义补全,对应 CompletionsCache 的 start_column 相等判定
  local session = state.lsp_session
  local session_continues = session
    and session.buf == bufnr
    and session.row == cur[1]
    and session.start_col == start_col
  local want_lsp = state.force_semantic or triggered or session_continues
  local use_lsp = opts.use_lsp and want_lsp and lsp.has_clients(bufnr)

  if use_lsp then
    state.lsp_session = { buf = bufnr, row = cur[1], start_col = start_col }
  else
    state.lsp_session = nil
  end

  if not query_len_ok and not triggered and not state.force_semantic
      and not path_items and not use_lsp then
    -- 对照 ycmd:所有 completer 的 ShouldUseNow 都失败 -> 空候选 -> 关菜单
    deliver(id, start_col, {})
    return
  end

  if not use_lsp then
    deliver(id, start_col, sync_items)
    return
  end

  -- 对照 YCM:等待服务端响应后一次性展示(10ms 轮询),不做两阶段交付,
  -- 否则菜单会在 [ID] 候选和 LSP 候选之间抖动
  lsp.request(bufnr, triggered and line_before:sub(-1) or nil,
    function(converted)
      if id ~= state.request_id then
        return
      end
      local ctx = state.req_ctx
      local items
      if #converted > 0 then
        local lsp_items = lsp.filter_and_sort(converted, ctx.query)
        if #lsp_items > 0 then
          if opts.lsp_merge_mode == 'merge' then
            items = lsp_items
            for _, it in ipairs(ctx.sync_items) do
              items[#items + 1] = it
            end
          else
            items = lsp_items -- exclusive:语义结果排他
          end
        else
          items = ctx.sync_items -- LSP 无匹配,回退 identifier(同 YCM)
        end
      else
        items = ctx.sync_items
      end
      -- 对照 CompletionsCache:语义结果为空时会话不再延续,
      -- 下一次按键回退到 identifier 补全
      if #converted == 0 and id == state.request_id then
        state.lsp_session = nil
      end
      deliver(id, ctx.start_col, items)
    end)
end

-- ---------------------------------------------------------------------------
-- 事件处理(对照 autoload/youcompleteme.vim 的各 s:On* 函数)
-- ---------------------------------------------------------------------------
local function on_text_changed_insert_mode(popup_is_visible)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].ycm_completing then
    return
  end

  -- 对照 s:OnTextChangedInsertMode:<C-n>/<C-p> 选中项导致的文本变化
  -- 不重新过滤(此时没有 InsertCharPre,last_char_inserted_by_user = false)
  if popup_is_visible and not state.last_char_inserted_by_user then
    return
  end

  if state.completion_stopped then
    state.completion_stopped = false
    return
  end

  local ft = vim.bo[bufnr].filetype

  -- 对照 s:IdentifierFinishedOperations:学习刚输入完成的标识符
  local finished, word = ident.identifier_finished_before_cursor(ft)
  if finished then
    if word then
      identifiers.add_identifier(bufnr, ft, word)
    end
    state.force_semantic = false
  end

  -- 对照:force_semantic 时输入了非标识符字符则退出 semantic 模式
  if state.force_semantic and not ident.last_char_is_identifier_char(ft)
      and not finished then
    state.force_semantic = false
  end

  local opts = options.get()
  if (opts.auto_trigger or state.force_semantic)
      and not inside_comment_or_string_and_should_stop()
      and not ident.on_blank_line() then
    request_completion(false)
  end
end

local function on_file_type_set(bufnr)
  if not M.allowed_in_buffer(bufnr) then
    return
  end
  vim.b[bufnr].ycm_completing = true
  local ft = vim.bo[bufnr].filetype
  identifiers.reparse_buffer(bufnr, ft)
end

local function on_buffer_enter(bufnr)
  if not M.allowed_in_buffer(bufnr) then
    return
  end
  vim.b[bufnr].ycm_completing = true
  -- 对照 s:OnBufferEnter:进入 buffer 时重新提取(内容可能被其他途径修改)
  identifiers.reparse_buffer(bufnr, vim.bo[bufnr].filetype)
end

local function on_insert_leave()
  state.force_semantic = false
  state.completion_stopped = false
  state.last_char_inserted_by_user = false
  state.lsp_session = nil
  state.request_id = state.request_id + 1
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].ycm_completing then
    -- 对照 s:OnInsertLeave -> OnFileReadyToParse:全量重建当前 buffer 词库
    identifiers.reparse_buffer(bufnr, vim.bo[bufnr].filetype)
  end
end

-- ---------------------------------------------------------------------------
-- setup / 用户命令
-- ---------------------------------------------------------------------------
local function set_up_global_options()
  -- 对照 s:SetUpCpoptions / s:SetUpCompleteopt
  vim.opt.cpoptions:append('B')
  vim.opt.shortmess:append('c')
  vim.opt.completeopt:remove({ 'menu', 'longest' })
  vim.opt.completeopt:append('menuone')
end

function M.setup(user_opts)
  local opts = options.setup(user_opts)

  vim.api.nvim_clear_autocmds({ group = AUGROUP })
  set_up_global_options()

  local function au(events, cb)
    vim.api.nvim_create_autocmd(events, { group = AUGROUP, callback = cb })
  end

  au('FileType', function(a) on_file_type_set(a.buf) end)
  au('BufEnter', function(a) on_buffer_enter(a.buf) end)
  au('BufWritePost', function(a)
    if vim.b[a.buf].ycm_completing then
      identifiers.reparse_buffer(a.buf, vim.bo[a.buf].filetype)
    end
  end)
  au('BufUnload', function(a) identifiers.remove_buffer(a.buf) end)

  -- 对照 s:OnInsertChar / s:OnCompleteDone / s:OnCompleteChanged
  au('InsertCharPre', function()
    state.last_char_inserted_by_user = true
  end)
  au('CompleteDone', function()
    state.last_char_inserted_by_user = false
    lsp.on_complete_done()
  end)
  au('CompleteChanged', function()
    -- 对照 s:OnCompleteChanged:仅在真正选中了某项时才标记非用户输入;
    -- 菜单随输入刷新时 v:event.completed_item 为空,不能动该标记,
    -- 否则紧随其后的 TextChangedP 会被误判为“选中项插入”而跳过重过滤
    local item = vim.v.event and vim.v.event.completed_item
    if item and not vim.tbl_isempty(item) then
      state.last_char_inserted_by_user = false
    end
  end)

  au('TextChangedI', function() on_text_changed_insert_mode(false) end)
  au('TextChangedP', function() on_text_changed_insert_mode(true) end)
  au('InsertLeave', on_insert_leave)

  keys.setup(opts, {
    on_stop = function()
      state.completion_stopped = true
    end,
    on_invoke = function()
      -- 对照 s:RequestSemanticCompletion
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.b[bufnr].ycm_completing then
        state.force_semantic = true
        request_completion(true)
      end
    end,
  })

  vim.api.nvim_create_user_command('YcmLuaDebugInfo', function()
    local total = 0
    local per_ft = {}
    for ft, d in pairs(identifiers.db) do
      local n = 0
      for _, entry in pairs(d) do
        for _ in pairs(entry.words) do
          n = n + 1
        end
      end
      per_ft[#per_ft + 1] = string.format('%s: %d', ft, n)
      total = total + n
    end
    table.sort(per_ft)
    print(('ycm.lua: %d identifiers cached'):format(total))
    for _, l in ipairs(per_ft) do
      print('  ' .. l)
    end
  end, {})

  -- setup 时对当前 buffer 生效(YCM 在 VimEnter 后也对首个文件补一次 FileType)
  local cur = vim.api.nvim_get_current_buf()
  if M.allowed_in_buffer(cur) then
    on_file_type_set(cur)
  end

  M._setup_done = true
end

function M.state()
  return state
end

return M

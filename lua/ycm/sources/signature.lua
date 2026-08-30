-- 签名帮助浮窗:对照 YCM 的 signature help(python/ycm/signature_help.py)
-- 与 ray-x/lsp_signature.nvim 的当前参数高亮。
--   - 触发:输入 server 声明的 signatureHelp trigger/retrigger 字符('(' ',' 等),
--     或签名会话激活中继续输入(更新当前参数)
--   - 展示:光标所在行上方的浮窗,锚定在会话激活时的位置(对照 YCM 的 anchor,
--     避免浮窗随输入横向跳动);当前参数用 extmark 高亮
--   - 当前参数:signature.activeParameter -> result.activeParameter ->
--     逗号计数兜底(对照 lsp_signature 的 helper.fallback)
local options = require('ycm.options')
local log = require('ycm.log')

local M = {}

local NS = vim.api.nvim_create_namespace('ycm_lua_signature')
M.NS = NS

M.state = {
  win = nil,
  buf = nil,
  req_id = 0,
  active = false,
  ts_lang = nil,   -- 浮窗 buffer 当前的 treesitter 语言
  pending = {},    -- 在途请求 client_id -> request_id
}

-- UTF-16 code unit 偏移 -> byte 偏移(LSP 的 label 偏移按 UTF-16 计)
local function byte_index_utf16(s, offset)
  -- nvim 0.11+: vim.str_byteindex(s, encoding, index, strict)
  local ok, res = pcall(vim.str_byteindex, s, 'utf-16', offset, false)
  if ok then
    return res
  end
  return vim.str_byteindex(s, offset, true) -- 旧签名:第三参为 use_utf16
end

-- 参数 label 两种形态(对照 lsp_signature helper.cal_active_parameter):
--   table { start, end }  : 相对 signature label 的 UTF-16 偏移
--   string                : label 的子串,从 search_from 起找
-- 返回 0 基 byte [s, e);失败返回 nil
local function param_range(label, param, search_from)
  local plabel = param.label
  if type(plabel) == 'table' then
    local s = byte_index_utf16(label, plabel[1])
    local e = byte_index_utf16(label, plabel[2])
    if s and e and e > s then
      return s, e
    end
    return nil
  end
  if type(plabel) == 'string' and plabel ~= '' then
    local s, e = label:find(plabel, (search_from or 0) + 1, true)
    if s then
      return s - 1, e
    end
  end
  return nil
end
M.param_range = param_range

-- 逗号计数兜底(参照 lsp_signature helper.fallback,加了嵌套感知):
-- 先向后找到外层调用的 '(',再向前只数同一层的 ','
local function fallback_active_parameter()
  local cur = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line():sub(1, cur[2])
  local call_start = nil
  local depth = 0
  for i = #line, 1, -1 do
    local c = line:sub(i, i)
    if c == ')' or c == ']' or c == '}' then
      depth = depth + 1
    elseif c == '(' or c == '[' or c == '{' then
      if depth == 0 then
        call_start = i
        break
      end
      depth = depth - 1
    end
  end
  if not call_start then
    return 0
  end
  local count, d = 0, 0
  for j = call_start + 1, #line do
    local c = line:sub(j, j)
    if c == '(' or c == '[' or c == '{' then
      d = d + 1
    elseif c == ')' or c == ']' or c == '}' then
      d = d - 1
    elseif c == ',' and d == 0 then
      count = count + 1
    end
  end
  return count
end
M.fallback_active_parameter = fallback_active_parameter

-- 光标前的字符(对照 ycmd 的缓冲区文本触发判定;不依赖 InsertCharPre,
-- 兼容 autopairs 等映射插入——映射展开的字符不触发 InsertCharPre)
local function char_before_cursor()
  local cur = vim.api.nvim_win_get_cursor(0)
  if cur[2] == 0 then
    return nil
  end
  local line = vim.api.nvim_get_current_line()
  local ch = line:sub(cur[2], cur[2])
  return ch ~= '' and ch or nil
end

-- 光标所在调用的函数名(pyright 等 server 的 label 不带函数名,如 open 的
-- label 以 '(' 开头,展示时补上;对照 YCM/Jedi 的显示效果)
local function callee_name()
  local cur = vim.api.nvim_win_get_cursor(0)
  local before = vim.api.nvim_get_current_line():sub(1, cur[2])
  local depth = 0
  for i = #before, 1, -1 do
    local c = before:sub(i, i)
    if c == ')' or c == ']' or c == '}' then
      depth = depth + 1
    elseif c == '(' then
      if depth == 0 then
        return before:sub(1, i - 1):match('([%w_%.:]+)%s*$')
      end
      depth = depth - 1
    elseif c == '[' or c == '{' then
      depth = depth - 1
    end
  end
  return nil
end
M.callee_name = callee_name

-- 支持签名帮助的 LSP 客户端(测试中可替换)
function M.clients(bufnr)
  return vim.lsp.get_clients({
    bufnr = bufnr,
    method = 'textDocument/signatureHelp',
  })
end

-- 取消在途请求(对照 lsp_signature;避免慢响应堆积拖垮 server)
function M.cancel_pending()
  for cid, rid in pairs(M.state.pending) do
    local client = vim.lsp.get_client_by_id(cid)
    if client then
      pcall(client.cancel_request, client, rid)
    end
  end
  M.state.pending = {}
end

-- LSP 请求(测试中可替换)。cb(result | nil)
function M.request(bufnr, trigger_char, is_retrigger, cb)
  local clients = M.clients(bufnr)
  if #clients == 0 then
    cb(nil)
    return
  end
  M.cancel_pending()
  local ok, params = pcall(vim.lsp.util.make_position_params, 0,
    clients[1].offset_encoding)
  if not ok then
    params = vim.lsp.util.make_position_params(0)
  end
  params.context = {
    triggerKind = is_retrigger and 3 or (trigger_char and 2 or 1),
    triggerCharacter = trigger_char,
    isRetrigger = is_retrigger,
  }
  local remaining = #clients
  local done = false
  local function finish(result)
    if done then
      return
    end
    if result and result.signatures and #result.signatures > 0 then
      done = true
      M.state.pending = {}
      cb(result)
      return
    end
    remaining = remaining - 1
    if remaining == 0 then
      done = true
      M.state.pending = {}
      cb(nil)
    end
  end
  for _, client in ipairs(clients) do
    local _, rid = client:request('textDocument/signatureHelp', params,
      function(err, result)
        finish(result)
      end, bufnr)
    if rid then
      M.state.pending[client.id] = rid
    end
  end
end

-- ---------------------------------------------------------------------------
-- 浮窗管理
-- ---------------------------------------------------------------------------
local function ensure_buf()
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    return M.state.buf
  end
  M.state.buf = vim.api.nvim_create_buf(false, true)
  -- 新 buffer 上没有 parser,重置缓存让 apply_syntax_highlight 重挂
  M.state.ts_lang = nil
  return M.state.buf
end

function M.close()
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end
  M.state.win = nil
  M.state.active = false
  M.state.req_id = M.state.req_id + 1 -- 使迟到的响应失效
  M.cancel_pending()
end

-- 浮窗 buffer 按源文件类型做 treesitter 语法高亮(截图效果:lsp_signature
-- 用 markdown fence 间接实现;我们直接在 buffer 上起 parser)
local function apply_syntax_highlight(buf, lang)
  if not lang then
    return
  end
  if M.state.ts_lang == lang and pcall(vim.treesitter.get_parser, buf) then
    return -- 该 buffer 已挂好 parser
  end
  pcall(vim.treesitter.stop, buf)
  if pcall(vim.treesitter.start, buf, lang) then
    M.state.ts_lang = lang
  else
    M.state.ts_lang = nil
  end
end

-- lines: 内容行(首行为签名);hl: { start_byte, end_byte }(0 基,首行)或 nil
function M.show(lines, hl, opts)
  opts = opts or {}
  local buf = ensure_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- markdown 代码围栏行整行隐藏(conceal_lines;需浮窗 conceallevel>0)
  for _, r in ipairs(opts.fence_rows or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, r, 0, { conceal_lines = '' })
  end
  if hl then
    -- priority 高于 treesitter(100),确保当前参数高亮不被语法高亮盖住
    vim.api.nvim_buf_set_extmark(buf, NS, opts.hl_row or 0, hl[1], {
      end_col = hl[2],
      hl_group = 'YcmSignatureActiveParameter',
      priority = 200,
      strict = false,
    })
  end
  apply_syntax_highlight(buf, opts.lang)

  local width = 1
  for i, l in ipairs(lines) do
    if not (opts.fence_rows and vim.tbl_contains(opts.fence_rows, i - 1)) then
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
  end
  width = math.min(width, vim.o.columns - 4, 100)
  -- 长签名折行展示(对照 lsp_signature),不截断;高度按折行后计算,上限 15
  local height = 0
  for i, l in ipairs(lines) do
    if not (opts.fence_rows and vim.tbl_contains(opts.fence_rows, i - 1)) then
      height = height + math.max(1,
        math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
  end
  height = math.min(height, 15)
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    -- 会话中:只更新内容与尺寸,位置保持锚定(对照 YCM 的 anchor 稳定性)
    vim.api.nvim_win_set_config(M.state.win, { width = width, height = height })
    return
  end

  -- 新会话:锚定在光标处(relative='cursor',不涉 gutter 换算),
  -- 优先上方,不够则翻到下方
  local above = vim.fn.winline() - 1 >= height + 2
  M.state.win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor',
    anchor = above and 'SW' or 'NW',
    row = above and 0 or 1,
    col = 0,
    width = width,
    height = height,
    border = 'single',
    style = 'minimal',
    focusable = false,
    noautocmd = true,
  })
  -- conceallevel>0 才会隐藏围栏行;wrap 折行长签名
  vim.wo[M.state.win].conceallevel = 2
  vim.wo[M.state.win].wrap = true
  vim.wo[M.state.win].showbreak = '↳ '
  M.state.active = true
  M.state.anchor_row = vim.api.nvim_win_get_cursor(0)[1]
end

-- 处理 signatureHelp 响应
function M.on_response(result, filetype)
  if not result or not result.signatures or #result.signatures == 0 then
    M.close()
    return
  end
  local sig = result.signatures[(result.activeSignature or 0) + 1]
    or result.signatures[1]
  local label = sig.label or ''
  local params = sig.parameters or {}

  local aidx = sig.activeParameter
  if type(aidx) ~= 'number' then
    aidx = result.activeParameter
  end
  -- pyright 的 activeParameter 可能是 overload 合并参数表的索引(越界);
  -- 越界/缺失时退回逗号计数(光标处的真实参数位),最后手段才是夹取
  if type(aidx) ~= 'number' or aidx < 0 or aidx >= #params then
    aidx = fallback_active_parameter()
  end
  if aidx >= #params then
    aidx = #params - 1
  end

  local hl = nil
  local param = aidx >= 0 and params[aidx + 1] or nil
  if param then
    -- string label 时从前一个参数的结束位置开始找(避免同名前缀误匹配)
    local search_from = 0
    if aidx > 0 and params[aidx] then
      local _, pe = param_range(label, params[aidx], 0)
      search_from = pe or 0
    end
    local s, e = param_range(label, param, search_from)
    if s then
      hl = { s, e }
    end
  end

  if #result.signatures > 1 then
    label = label .. ('  (+%d overloads)'):format(#result.signatures - 1)
  end

  -- pyright 等的 label 不带函数名(以 '(' 开头),补上被调名;
  -- 注意 hl 偏移基于原始 label,前缀后整体平移
  if label:sub(1, 1) == '(' then
    local callee = callee_name()
    if callee then
      label = callee .. label
      if hl then
        hl = { hl[1] + #callee, hl[2] + #callee }
      end
    end
  end

  -- 内容:对照 lsp_signature 的 markdown 方案——签名装进代码围栏
  -- (injection 只对签名行做该语言的语法染色,文档不会再被当代码染色),
  -- 围栏行整行隐藏;宽度上限 100,超长签名在浮窗内折行展示
  local lang = filetype and vim.treesitter.language.get_lang(filetype)
    or filetype

  local doc = sig.documentation
  if type(doc) == 'table' then
    doc = doc.value -- MarkupContent
  end
  local has_doc = type(doc) == 'string' and doc:match('%S') ~= nil

  local lang = filetype and vim.treesitter.language.get_lang(filetype)
    or filetype

  local lines, hl_row, fence_rows, show_lang
  if has_doc then
    lines = { '```' .. (lang or ''), label, '```' }
    table.insert(lines, string.rep('─',
      math.min(vim.fn.strdisplaywidth(label), 100)))
    local dl = 0
    for line in (vim.trim(doc:gsub('\r\n', '\n')) .. '\n'):gmatch('(.-)\n') do
      table.insert(lines, line)
      dl = dl + 1
      if dl >= 12 then -- 文档行数上限,防止浮窗占屏
        break
      end
    end
    hl_row = 1
    fence_rows = { 0, 2 }
    show_lang = 'markdown' -- 围栏内的 lang 由 injection 负责
  else
    lines = { label }
    hl_row = 0
    show_lang = lang
  end
  M.show(lines, hl, { hl_row = hl_row, fence_rows = fence_rows,
    lang = show_lang })
end


-- TextChangedI 时调用
function M.on_text_changed(bufnr)
  if not options.get().signature_help then
    return
  end
  local clients = M.clients(bufnr)
  if #clients == 0 then
    if M.state.active then
      M.close()
    end
    return
  end

  local last_char = char_before_cursor()
  local is_trigger = false
  local is_retrigger = false
  if last_char then
    for _, client in ipairs(clients) do
      local cp = client.server_capabilities
        and client.server_capabilities.signatureHelpProvider
      if cp then
        if vim.tbl_contains(cp.triggerCharacters or {}, last_char) then
          is_trigger = true
        end
        if vim.tbl_contains(cp.retriggerCharacters or {}, last_char) then
          is_retrigger = true
        end
        if is_trigger or is_retrigger then
          break
        end
      end
    end
  end

  -- 触发字符,或会话激活中(更新当前参数高亮)。会话中的频繁请求靠
  -- cancel_pending 取消在途旧请求(对照 lsp_signature),不会堆积拖垮 server
  if not is_trigger and not is_retrigger and not M.state.active then
    return
  end

  M.state.req_id = M.state.req_id + 1
  local id = M.state.req_id
  local was_active = M.state.active
  local ft = vim.bo[bufnr].filetype
  log.add('[sig] request id=%d trigger=%s retrigger=%s', id,
    tostring(is_trigger and last_char or nil), tostring(was_active))
  M.request(bufnr, is_trigger and last_char or nil, was_active,
    function(result)
      log.add('[sig] response id=%d signatures=%s', id,
        result and tostring(#(result.signatures or {})) or 'nil')
      if id ~= M.state.req_id then
        return
      end
      vim.schedule(function()
        if id ~= M.state.req_id then
          return
        end
        local mode = vim.api.nvim_get_mode().mode
        if mode:sub(1, 1) ~= 'i' and mode:sub(1, 1) ~= 'R' then
          return
        end
        M.on_response(result, ft)
      end)
    end)
  -- 超时死等兜底:server 卡死时取消请求,不能让它阻塞后续补全
  vim.defer_fn(function()
    if id == M.state.req_id and next(M.state.pending) then
      log.add('[sig] timeout cancel id=%d', id)
      M.cancel_pending()
    end
  end, 3000)
end

return M

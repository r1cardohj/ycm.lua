-- Treesitter 辅助模块。所有入口都遵循同一约定:
-- 没有 parser(或查询)时返回 nil,由调用方走非 treesitter 的 fallback 路径。
local M = {}

function M.get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok then
    return parser
  end
  return nil
end

-- 当前 buffer 中所有 @comment*/@string* capture 的 range 列表
-- { start_row, start_col, end_row, end_col }(0 基,end 开区间);无 parser 返回 nil
function M.comment_string_ranges(bufnr)
  local parser = M.get_parser(bufnr)
  if not parser then
    return nil
  end
  local ok, query = pcall(vim.treesitter.query.get, parser:lang(), 'highlights')
  if not ok or not query then
    return nil
  end
  local pok, trees = pcall(parser.parse, parser)
  if not pok or not trees then
    return nil
  end

  local ranges = {}
  for _, tree in ipairs(trees) do
    for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
      local name = query.captures[id]
      if name and (name:find('^comment') or name:find('^string')) then
        local sr, sc, er, ec = node:range()
        ranges[#ranges + 1] = { sr, sc, er, ec }
      end
    end
  end
  return ranges
end

-- 把 ranges 覆盖的文本替换为等宽空白(保留行结构,便于后续按行处理)
function M.blank_ranges(lines, ranges)
  for _, r in ipairs(ranges) do
    local sr, sc, er, ec = r[1] + 1, r[2], r[3] + 1, r[4]
    for row = sr, er do
      local line = lines[row]
      if line then
        local s = (row == sr) and sc or 0
        local e = (row == er) and ec or #line
        e = math.min(e, #line)
        if e > s then
          lines[row] = line:sub(1, s)
            .. string.rep(' ', e - s)
            .. line:sub(e + 1)
        end
      end
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- 关键字播种:从 queries/<lang>/highlights.scm 的字面量中提取语言关键字
-- (现代版 ycm_seed_identifiers_with_syntax)。无 parser/查询时返回 nil,
-- 调用方静默跳过(该特性的 fallback 即“不播种”)。
-- ---------------------------------------------------------------------------

-- 对照 YCM 从 Statement/Type/PreProc/Boolean/Identifier 根组提取
local WANTED_CAPTURES = {
  '^keyword',
  '^type%.builtin',
  '^constant%.builtin',
  '^boolean',
  '^function%.builtin',
  '^include',
  '^preproc',
  '^define',
}

local function wanted_capture(cap)
  for _, pat in ipairs(WANTED_CAPTURES) do
    if cap:match(pat) then
      return true
    end
  end
  return false
end

-- 从 highlights.scm 文本提取关键字:
--   "word" @capture        单个字面量
--   [ "w1" "w2" ] @capture  字面量列表
-- 断言中的字符串(如 (#eq? @foo "bar"))后面不跟 capture,天然被排除
local function extract_keywords_from_query_text(text, out)
  for word, cap in text:gmatch('"([^"]+)"%s*@([%w_%.%-]+)') do
    if wanted_capture(cap) then
      out[word] = true
    end
  end
  for block, cap in text:gmatch('%[([^%]]-)%]%s*@([%w_%.%-]+)') do
    if wanted_capture(cap) then
      for word in block:gmatch('"([^"]+)"') do
        out[word] = true
      end
    end
  end
end

function M.keywords_for_lang(lang, visited)
  visited = visited or {}
  if visited[lang] then
    return {}
  end
  visited[lang] = true

  local ok, files = pcall(vim.treesitter.query.get_files, lang, 'highlights')
  if not ok or not files or #files == 0 then
    return nil
  end

  local out = {}
  local found = false
  for _, path in ipairs(files) do
    local f = io.open(path)
    if f then
      found = true
      local text = f:read('a')
      f:close()
      extract_keywords_from_query_text(text, out)
      -- 跟随 inherits 模型行(如 typescript inherits javascript)
      local inherits = text:match('^;+%s*inherits:%s*([%w_,%s]+)')
      if inherits then
        for parent in inherits:gmatch('[%w_]+') do
          for w in pairs(M.keywords_for_lang(parent, visited) or {}) do
            out[w] = true
          end
        end
      end
    end
  end
  return found and out or nil
end

-- filetype -> treesitter lang(如 javascriptreact -> javascript)
function M.keywords_for_filetype(ft)
  local lang = ft
  local ok, mapped = pcall(vim.treesitter.language.get_lang, ft)
  if ok and mapped then
    lang = mapped
  end
  return M.keywords_for_lang(lang)
end

-- 光标处的 treesitter 节点(先强制增量解析,否则 get_node 可能返回 nil
-- 或旧树)。无 parser 时返回 nil。
-- 注意:取光标前一个字符的位置(对照 YCM 的 synID(line('.'), col('.')-1, 1)),
-- 否则行尾光标恰好落在 comment/string 节点的开边界外,检测会失效。
function M.node_at_cursor(bufnr)
  bufnr = bufnr or 0
  local parser = M.get_parser(bufnr)
  if not parser then
    return nil
  end
  pcall(parser.parse, parser) -- 增量解析,便宜
  local cur = vim.api.nvim_win_get_cursor(0)
  local col = cur[2] > 0 and cur[2] - 1 or 0
  local ok, node = pcall(vim.treesitter.get_node,
    { bufnr = bufnr, pos = { cur[1] - 1, col } })
  if ok then
    return node
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- 上下文检测:光标是否位于 import/require 语句的字符串参数内
-- (用于放宽路径补全的触发条件)。返回 true / false;无 parser 时返回 nil
-- (fallback:调用方维持原有行为)。
-- ---------------------------------------------------------------------------
function M.in_import_string(bufnr)
  bufnr = bufnr or 0
  if not M.get_parser(bufnr) then
    return nil
  end
  local node = M.node_at_cursor(bufnr)
  if not node then
    return false
  end
  local in_string = false
  while node do
    local t = node:type()
    if t:find('string') then
      in_string = true
    end
    -- python: import_statement/import_from_statement
    -- c/cpp:  preproc_include; js/ts: import_statement; rust: use_declaration
    if t:find('import') or t:find('include') or t == 'use_declaration' then
      return in_string
    end
    -- lua 等: require('...') 是普通函数调用,看被调函数名
    if t == 'function_call' or t == 'call_expression' then
      local name_node = node:named_child(0)
      if name_node then
        local nok, txt = pcall(vim.treesitter.get_node_text, name_node, bufnr)
        if nok and txt == 'require' then
          return in_string
        end
      end
    end
    node = node:parent()
  end
  return false
end

-- ---------------------------------------------------------------------------
-- 成员访问学习:收集 receiver.member / receiver->member / receiver:method
-- 的从属关系(receiver 须为单个标识符节点,链式访问如 a.b.c 不展开)。
-- 返回 { receiver -> { member -> true } };无 parser 时返回 nil(fallback:
-- 调用方退回纯标识符补全)。
-- ---------------------------------------------------------------------------
function M.collect_member_accesses(bufnr)
  local parser = M.get_parser(bufnr)
  if not parser then
    return nil
  end
  local ok, query = pcall(vim.treesitter.query.get, parser:lang(), 'highlights')
  if not ok or not query then
    return nil
  end
  local pok, trees = pcall(parser.parse, parser)
  if not pok or not trees then
    return nil
  end

  local out = {}
  for _, tree in ipairs(trees) do
    for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
      local name = query.captures[id]
      if name and (name:find('property') or name:find('field')
          or name:find('member') or name:find('method')) then
        -- 成员节点的父节点的第一个 named child 是 receiver
        local parent = node:parent()
        local recv = parent and parent:named_child(0)
        if recv and recv ~= node and recv:type():find('identifier') then
          local rok, rtext = pcall(vim.treesitter.get_node_text, recv, bufnr)
          local mok, mtext = pcall(vim.treesitter.get_node_text, node, bufnr)
          if rok and mok
              and rtext:match('^[%a_][%w_]*$')
              and mtext:match('^[%a_][%w_]*$') then
            local set = out[rtext]
            if not set then
              set = {}
              out[rtext] = set
            end
            set[mtext] = true
          end
        end
      end
    end
  end
  return out
end

return M

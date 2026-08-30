-- 移植 ycmd 的 identifier_utils.py 与 ycm/base.py 中的标识符逻辑:
--   - 按 filetype 的 identifier 规则(默认 [^\W\d]\w*,js 带 $,css 带 -,html 特殊)
--   - 注释/字符串剔除(默认不收集注释与字符串中的标识符)
--   - 光标前最长标识符 = query / 补全起点(StartOfLongestIdentifierEndingAtIndex)
--   - 刚输入完成的标识符检测(base.CurrentIdentifierFinished)
local options = require('ycm.options')

local M = {}

-- ---------------------------------------------------------------------------
-- 按 filetype 的标识符字符规则(单字节 Lua pattern 字符类;
-- [\128-\255] 覆盖所有 UTF-8 多字节字符的每个字节,近似 [^\W\d] 中的 unicode 部分)
-- ---------------------------------------------------------------------------
local RULES = {
  -- DEFAULT_IDENTIFIER_REGEX = [^\W\d]\w*
  default = {
    start = '[%a_\128-\255]',
    rest = '[%w_\128-\255]',
  },
  -- javascript: (?:[^\W\d]|\$)[\w$]*
  javascript = {
    start = '[%a$_\128-\255]',
    rest = '[%w$_\128-\255]',
  },
  -- css: -?[^\W\d][\w-]*
  css = {
    start = '[%-%a_\128-\255]',
    rest = '[%w%-_\128-\255]',
  },
  -- html: [a-zA-Z][^\s/>='\"}{.]*
  html = {
    start = '[a-zA-Z]',
    rest = "[^%s/>='\"}{%.]",
  },
}

local FT_RULES = {
  javascript = RULES.javascript,
  javascriptreact = RULES.javascript,
  typescript = RULES.javascript,
  typescriptreact = RULES.javascript,
  css = RULES.css,
  html = RULES.html,
}

local function rules_for(ft)
  return FT_RULES[ft] or RULES.default
end
M.rules_for = rules_for

-- ---------------------------------------------------------------------------
-- 注释/字符串剔除(对照 identifier_utils.py 的
-- FILETYPE_TO_COMMENT_AND_STRING_REGEX;把内容替换为等长空白,保留换行)
-- ---------------------------------------------------------------------------
local CLEAN_CONFIGS = {
  default = {
    line = { '//', '#' },
    block = { '/*', '*/' },
    triple = { "'''", '"""' },
    strings = { "'", '"' },
  },
  cpp = {
    line = { '//' },
    block = { '/*', '*/' },
    strings = { "'", '"' },
  },
  go = {
    line = { '//' },
    block = { '/*', '*/' },
    strings = { "'", '"', '`' },
  },
  python = {
    line = { '#' },
    triple = { "'''", '"""' },
    strings = { "'", '"' },
  },
  rust = {
    line = { '//' },
    strings = { "'", '"' },
  },
}
for _, ft in ipairs({ 'c', 'cuda', 'objc', 'objcpp', 'javascript',
  'typescript', 'javascriptreact', 'typescriptreact', 'java', 'cs', 'php',
  'lua' }) do
  CLEAN_CONFIGS[ft] = CLEAN_CONFIGS.cpp
end
CLEAN_CONFIGS.lua = { line = { '--' }, strings = { "'", '"' } }

local function strip_comments_and_strings(text, ft)
  local cfg = CLEAN_CONFIGS[ft] or CLEAN_CONFIGS.default
  local n = #text
  local i = 1
  local out = {}

  -- 把 text[a..b] 中的非换行字符以空格写入 out
  local function blank(a, b)
    local j = a
    while j <= b do
      local nl = text:find('\n', j, true)
      if not nl or nl > b then
        out[#out + 1] = string.rep(' ', b - j + 1)
        return
      end
      out[#out + 1] = string.rep(' ', nl - j)
      out[#out + 1] = '\n'
      j = nl + 1
    end
  end

  while i <= n do
    local handled = false

    if cfg.line then
      for _, lc in ipairs(cfg.line) do
        if text:sub(i, i + #lc - 1) == lc then
          local j = text:find('\n', i, true) or (n + 1)
          blank(i, j - 1)
          i = j
          handled = true
          break
        end
      end
    end

    if not handled and cfg.block
        and text:sub(i, i + 1) == cfg.block[1] then
      local j = text:find(cfg.block[2], i + 2, true)
      local e = j and (j + #cfg.block[2] - 1) or n
      blank(i, e)
      i = e + 1
      handled = true
    end

    if not handled and cfg.triple then
      for _, t in ipairs(cfg.triple) do
        if text:sub(i, i + #t - 1) == t then
          local j = text:find(t, i + #t, true)
          local e = j and (j + #t - 1) or n
          blank(i, e)
          i = e + 1
          handled = true
          break
        end
      end
    end

    if not handled and cfg.strings then
      local q = text:sub(i, i)
      if q == cfg.strings[1] or q == cfg.strings[2] or q == cfg.strings[3] then
        local j = i + 1
        while j <= n do
          local cj = text:sub(j, j)
          if cj == '\\' then
            j = j + 2
          elseif cj == q then
            break
          elseif cj == '\n' then
            break -- 字符串不跨行(简化,同 YCM 的正则近似)
          else
            j = j + 1
          end
        end
        local e = math.min(j, n)
        if j > n or text:sub(j, j) ~= q then
          e = j - 1 -- 未闭合
        end
        blank(i, math.max(e, i))
        i = math.max(e, i) + 1
        handled = true
      end
    end

    if not handled then
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end

  return table.concat(out)
end
M.strip_comments_and_strings = strip_comments_and_strings

-- ---------------------------------------------------------------------------
-- 从文本提取标识符集合
-- ---------------------------------------------------------------------------
function M.identifiers_from_text(text, ft)
  if not options.get().collect_identifiers_from_comments_and_strings then
    text = strip_comments_and_strings(text, ft)
  end
  local rules = rules_for(ft)
  -- rules.start/rest 均为形如 '[%a_...]' 的字符类,直接拼接
  local pat = rules.start .. rules.rest .. '*'
  local words = {}
  for w in text:gmatch(pat) do
    words[w] = true
  end
  return words
end

-- ---------------------------------------------------------------------------
-- 光标上下文计算
-- ---------------------------------------------------------------------------

-- 返回当前行、光标 byte 列(1-based,同 col('.'))
function M.current_line_and_col()
  return vim.api.nvim_get_current_line(), vim.fn.col('.')
end

-- 对应 RequestWrap 的 query/start_column:
-- 光标前以光标结尾的最长标识符;返回 (start_col, query)。
-- start_col 是 1-based byte 列,与 complete() 参数一致;无标识符时 start_col=col。
function M.query_at_cursor(ft)
  local line, col = M.current_line_and_col()
  local before = line:sub(1, col - 1)
  local rules = rules_for(ft)

  local i = col - 1
  while i >= 1 and before:sub(i, i):match(rules.rest) do
    i = i - 1
  end
  local start = i + 1

  -- 标识符首字符不能是数字、且须满足 start 规则(YCM 正则 [^\W\d] 同理)
  while start < col do
    local c = before:sub(start, start)
    if not c:match('%d') and c:match(rules.start) then
      break
    end
    start = start + 1
  end

  return start, before:sub(start)
end

-- 对应 base.CurrentIdentifierFinished:光标前一个字符不是标识符字符,
-- 但再前一个字符恰是某标识符的结尾(或光标前整行空白)。
-- 返回 finished(bool) 与刚完成的标识符(可能为 nil)。
-- 注意:vimsupport.CurrentLineContentsAndCodepointColumn 返回的是 0 基列,
-- match.end() == previous_char_index 即标识符结束于光标前一个字符处。
function M.identifier_finished_before_cursor(ft)
  local line, col = M.current_line_and_col()
  if col < 3 then
    return true, nil
  end
  local rules = rules_for(ft)
  local prev = line:sub(col - 1, col - 1)     -- 光标前的字符
  if prev:match(rules.rest) then
    return false, nil                          -- 光标仍在标识符内部/末尾
  end
  local before_prev = line:sub(col - 2, col - 2)
  if not before_prev:match(rules.rest) then
    -- 光标前整行空白也视为 finished(用户可能在上一行结束了标识符)
    if line:sub(1, col - 1):match('^%s*$') then
      return true, nil
    end
    return false, nil
  end
  -- 向前提取结束于 col-2 的完整标识符
  local i = col - 2
  while i >= 1 and line:sub(i, i):match(rules.rest) do
    i = i - 1
  end
  local start = i + 1
  while start <= col - 2 and line:sub(start, start):match('%d') do
    start = start + 1
  end
  local word = line:sub(start, col - 2)
  if word == '' then
    word = nil
  end
  return true, word
end

-- 对应 base.LastEnteredCharIsIdentifierChar
function M.last_char_is_identifier_char(ft)
  local line, col = M.current_line_and_col()
  if col < 2 then
    return false
  end
  return line:sub(col - 1, col - 1):match(rules_for(ft).rest) ~= nil
end

function M.on_blank_line()
  local line = vim.api.nvim_get_current_line()
  return line == '' or line:match('^%s*$') ~= nil
end

-- 字符数(codepoint 级,用于 min_num_of_chars_for_completion 判断)
function M.char_count(s)
  local n = 0
  for _ in require('ycm.char').iter_chars(s) do
    n = n + 1
  end
  return n
end

return M

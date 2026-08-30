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

return M

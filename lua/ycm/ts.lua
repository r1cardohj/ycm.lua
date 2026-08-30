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

return M

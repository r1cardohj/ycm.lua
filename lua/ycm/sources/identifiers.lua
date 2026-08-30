-- 标识符数据源:对照 ycmd 的 IdentifierCompleter / IdentifierDatabase。
-- 数据库按 filetype 隔离(YCM 只会用与当前 buffer 相同 filetype 的标识符),
-- 每个 buffer 存一份词集合;当前 buffer 增量学习刚输入完成的标识符,
-- 在 BufEnter/BufWritePost/InsertLeave 时全量重建。
local ident = require('ycm.ident')
local match = require('ycm.match')
local options = require('ycm.options')

local M = {}

-- db[ft][bufnr] = { words = { word -> true } }
-- 特殊 key '__keywords__':treesitter 关键字播种的伪 buffer 条目
M.db = {}

-- 已播种过的 filetype
M.seeded = {}

-- word -> Candidate 的预处理缓存(weak values,GC 友好)
M.cand_cache = setmetatable({}, { __mode = 'v' })

local function db_for(ft)
  local d = M.db[ft]
  if not d then
    d = {}
    M.db[ft] = d
  end
  return d
end

-- 全量重建某 buffer 的标识符。
-- 剔除注释/字符串时优先用 treesitter 的 @comment/@string capture(精确),
-- 无 parser 时回退手写 scanner(对照 ycmd 的正则剔除)。
function M.reparse_buffer(bufnr, ft)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local text
  if options.get().collect_identifiers_from_comments_and_strings then
    text = table.concat(lines, '\n')
    db_for(ft)[bufnr] = { words = ident.extract_identifiers(text, ft) }
    return
  end
  local ranges = require('ycm.ts').comment_string_ranges(bufnr)
  if ranges then
    text = table.concat(require('ycm.ts').blank_ranges(lines, ranges), '\n')
    db_for(ft)[bufnr] = { words = ident.extract_identifiers(text, ft) }
  else
    text = table.concat(lines, '\n')
    db_for(ft)[bufnr] = { words = ident.identifiers_from_text(text, ft) }
  end
end

-- 增量加入一个刚输入完成的标识符
function M.add_identifier(bufnr, ft, word)
  if word == '' then
    return
  end
  local d = db_for(ft)
  local entry = d[bufnr]
  if not entry then
    entry = { words = {} }
    d[bufnr] = entry
  end
  entry.words[word] = true
end

function M.remove_buffer(bufnr)
  for _, d in pairs(M.db) do
    d[bufnr] = nil
  end
end

-- buffer 的 filetype 变化时迁移数据
function M.move_buffer(bufnr, old_ft, new_ft)
  local old = M.db[old_ft]
  if old and old[bufnr] then
    db_for(new_ft)[bufnr] = old[bufnr]
    old[bufnr] = nil
  end
end

-- 从 treesitter highlights 查询中提取语言关键字,播种进该 filetype 的词库
-- (每个 filetype 只做一次;无 parser/查询时静默跳过)
function M.ensure_seeded(ft)
  if M.seeded[ft] then
    return
  end
  M.seeded[ft] = true
  if not options.get().seed_identifiers_with_syntax then
    return
  end
  local kws = require('ycm.ts').keywords_for_filetype(ft)
  if kws and next(kws) then
    -- 过滤掉非标识符字面量(如 C 的 "#include")
    local filtered = {}
    for w in pairs(kws) do
      if ident.is_identifier(w, ft) then
        filtered[w] = true
      end
    end
    if next(filtered) then
      db_for(ft)['__keywords__'] = { words = filtered }
    end
  end
end

-- 对照 IdentifierCompleter::CandidatesForQueryAndType:
-- 汇总同 filetype 所有 buffer 的标识符,做子序列过滤 + YCM 排序,
-- 截断到 max_num_identifier_candidates
function M.collect(query, ft)
  M.ensure_seeded(ft)
  local opts = options.get()
  local d = M.db[ft]
  if not d then
    return {}
  end

  local words = {}
  local seen = {}
  local min_len = opts.min_num_identifier_candidate_chars
  for _, entry in pairs(d) do
    for w in pairs(entry.words) do
      if not seen[w] and ident.char_count(w) >= min_len then
        seen[w] = true
        words[#words + 1] = w
      end
    end
  end

  return match.filter_and_sort(
    words, query, opts.max_num_identifier_candidates, M.cand_cache)
end

return M

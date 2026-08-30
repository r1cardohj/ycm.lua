-- 移植 ycm_core 的匹配/排序核心:
--   Candidate.cpp  -> Candidate 预处理(word boundary chars、大小写)与子序列匹配
--   Result.cpp     -> 排序键(LCS、首字符、前缀、index sum...)与比较链
local char = require('ycm.char')

local M = {}

-- ---------------------------------------------------------------------------
-- Candidate(对应 cpp/ycm/Candidate.h)
-- ---------------------------------------------------------------------------
local Candidate = {}
Candidate.__index = Candidate

function M.new_candidate(text)
  local chars = char.to_chars(text)

  -- ComputeWordBoundaryChars:词边界字符 = 首字符(非标点)、小写/非标点后的大写、
  -- 标点后的字母,即 "FooBar_baz" 的边界为 F、B、b
  local wb = {}
  if #chars > 0 and not chars[1].is_punct then
    wb[#wb + 1] = chars[1]
  end
  for i = 2, #chars do
    local prev, c = chars[i - 1], chars[i]
    if (not prev.is_upper and c.is_upper) or (prev.is_punct and c.is_letter) then
      wb[#wb + 1] = c
    end
  end

  -- ComputeTextIsLowercase / ComputeCaseSwappedText
  local is_lower = true
  local swapped_parts = {}
  for i, c in ipairs(chars) do
    if c.is_upper then
      is_lower = false
    end
    swapped_parts[i] = c.swapped
  end

  return setmetatable({
    text = text,
    chars = chars,
    length = #chars,
    wb_chars = wb,
    wb_count = #wb,
    text_is_lowercase = is_lower,
    case_swapped_text = table.concat(swapped_parts),
  }, Candidate)
end

-- 对应 Candidate::QueryMatchResult:子序列扫描(query 字符按序出现在候选中),
-- 返回 nil(不匹配)或 result 骨架
local function query_match_result(query_chars, cand)
  local qlen = #query_chars
  if qlen == 0 then
    return { candidate = cand, index_sum = 0, is_prefix = false }
  end
  if cand.length < qlen then
    return nil
  end

  local qi = 1
  local index_sum = 0
  local cchars = cand.chars
  for ci = 1, cand.length do
    if char.matches_smart(query_chars[qi], cchars[ci]) then
      index_sum = index_sum + (ci - 1)
      if qi == qlen then
        -- C++: candidate_index == query_index(0 基),即所有匹配从头连续
        return {
          candidate = cand,
          index_sum = index_sum,
          is_prefix = ci == qi,
        }
      end
      qi = qi + 1
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Result(对应 cpp/ycm/Result.cpp)
-- ---------------------------------------------------------------------------

-- LongestCommonSubsequenceLength(query, word_boundary_chars),EqualsBase 比较
local function lcs_length(query_chars, wb_chars)
  local n, m = #query_chars, #wb_chars
  if n == 0 or m == 0 then
    return 0
  end
  local prev = {}
  local cur = {}
  for j = 0, m do
    prev[j] = 0
    cur[j] = 0
  end
  for i = 1, n do
    local qc = query_chars[i]
    cur[0] = 0
    for j = 1, m do
      if qc.base == wb_chars[j].base then
        cur[j] = prev[j - 1] + 1
      else
        cur[j] = math.max(cur[j - 1], prev[j])
      end
    end
    prev, cur = cur, prev
  end
  return prev[m]
end

-- 对应 Result::SetResultFeaturesFromQuery
local function set_features(result, query_chars)
  local cand = result.candidate
  if #query_chars == 0 or cand.length == 0 then
    result.first_char_same = false
    result.num_wb_matches = 0
    return
  end
  result.first_char_same =
    char.equals_base(cand.chars[1], query_chars[1])
  result.num_wb_matches = lcs_length(query_chars, cand.wb_chars)
end

-- 对应 Result::operator< 的比较链(详见 Result.cpp 注释)
local function result_less(a, b)
  if a.query_len > 0 then
    -- 1. 首字符与 query 首字符相同者优先
    if a.first_char_same ~= b.first_char_same then
      return a.first_char_same
    end

    -- 2. 某一方 word-boundary 字符全部匹配时:wb 匹配数多者优,
    --    相同则 wb 字符总数少者优
    local qlen = a.query_len
    if a.num_wb_matches == qlen or b.num_wb_matches == qlen then
      if a.num_wb_matches ~= b.num_wb_matches then
        return a.num_wb_matches > b.num_wb_matches
      end
      if a.candidate.wb_count ~= b.candidate.wb_count then
        return a.candidate.wb_count < b.candidate.wb_count
      end
    end

    -- 3. query 是候选前缀者优先
    if a.is_prefix ~= b.is_prefix then
      return a.is_prefix
    end

    -- 4. wb 匹配数多者优
    if a.num_wb_matches ~= b.num_wb_matches then
      return a.num_wb_matches > b.num_wb_matches
    end

    -- 5. wb 字符总数少者优
    if a.candidate.wb_count ~= b.candidate.wb_count then
      return a.candidate.wb_count < b.candidate.wb_count
    end

    -- 6. 匹配位置下标之和小者优
    if a.index_sum ~= b.index_sum then
      return a.index_sum < b.index_sum
    end

    -- 7. 候选短者优
    if a.candidate.length ~= b.candidate.length then
      return a.candidate.length < b.candidate.length
    end

    -- 8. 全小写候选优先
    if a.candidate.text_is_lowercase ~= b.candidate.text_is_lowercase then
      return a.candidate.text_is_lowercase
    end
  end

  -- 9. case-swapped 字典序(即小写优先的字典序,"foo" < "Foo")
  return a.candidate.case_swapped_text < b.candidate.case_swapped_text
end
M.result_less = result_less

-- 对一批文本候选做过滤+排序(对应 ycm_core FilterAndSortCandidates)。
-- words: string 数组(允许重复,内部去重)
-- cand_cache: 可选,word -> Candidate 的缓存(由调用方持有,可跨请求复用)
-- 返回按 YCM 规则排序的字符串数组(至多 max_candidates 个)
function M.filter_and_sort(words, query, max_candidates, cand_cache)
  local query_chars = char.to_chars(query)
  local results = {}
  local seen = {}

  for _, text in ipairs(words) do
    if not seen[text] then
      seen[text] = true
      local cand
      if cand_cache then
        cand = cand_cache[text]
        if not cand then
          cand = M.new_candidate(text)
          cand_cache[text] = cand
        end
      else
        cand = M.new_candidate(text)
      end
      local r = query_match_result(query_chars, cand)
      if r then
        r.query_len = #query_chars
        set_features(r, query_chars)
        results[#results + 1] = r
      end
    end
  end

  table.sort(results, result_less)

  local out = {}
  local n = math.min(#results, max_candidates or #results)
  for i = 1, n do
    out[i] = results[i].candidate.text
  end
  return out
end

return M

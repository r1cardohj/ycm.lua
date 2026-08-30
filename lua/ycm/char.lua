-- 移植 ycm_core 的 Character(cpp/ycm/Character.h):
--   - smart case 匹配:query 字符为小写时大小写不敏感,大写时只匹配大写
--   - smart base 匹配:ycm_core 用 ICU 做 NFD 分解取 base(é→e),这里用一张
--     常见拉丁音调字符表近似
local M = {}

-- UTF-8 字符迭代器(返回字符子串),LuaJIT 没有 utf8 库
function M.iter_chars(s)
  local i = 1
  local n = #s
  return function()
    if i > n then
      return nil
    end
    local b = string.byte(s, i)
    local len
    if b < 0x80 then
      len = 1
    elseif b < 0xE0 then
      len = 2
    elseif b < 0xF0 then
      len = 3
    else
      len = 4
    end
    local c = string.sub(s, i, i + len - 1)
    i = i + len
    return c
  end
end

-- 常见带音调拉丁字符 -> base 字符(ycm_core NFD base 的近似)
local base_map = {}
do
  local groups = {
    { 'a', 'àáâãäåāăą' },
    { 'c', 'çćč' },
    { 'e', 'èéêëēėę' },
    { 'g', 'ĝğ' },
    { 'i', 'ìíîïī' },
    { 'n', 'ñń' },
    { 'o', 'òóôõöøō' },
    { 's', 'śšş' },
    { 'u', 'ùúûüū' },
    { 'y', 'ýÿ' },
    { 'z', 'žźż' },
  }
  for _, g in ipairs(groups) do
    for c in M.iter_chars(g[2]) do
      base_map[c] = g[1]
    end
  end
  -- 大写版本
  local upper_map = {}
  for c, b in pairs(base_map) do
    upper_map[vim.fn.toupper(c)] = vim.fn.toupper(b)
  end
  for c, b in pairs(upper_map) do
    base_map[c] = b
  end
end

local Char = {}
Char.__index = Char

-- 对应 ycm_core 的 Character:一个 UTF-8 字符及其属性
function M.new(c)
  local b = string.byte(c, 1)
  local is_ascii = b < 128
  local normal = c
  local lower, upper
  if is_ascii then
    if b >= 65 and b <= 90 then
      lower = string.char(b + 32)
      upper = c
    elseif b >= 97 and b <= 122 then
      lower = c
      upper = string.char(b - 32)
    else
      lower = c
      upper = c
    end
  else
    lower = vim.fn.tolower(c)
    upper = vim.fn.toupper(c)
  end

  local base = base_map[c] or c

  local is_letter, is_upper, is_punct
  if is_ascii then
    is_letter = (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
    is_upper = b >= 65 and b <= 90
    -- C ispunct 在 ASCII 下包含 '_'(与 Unicode Pc 类别一致,对应 ycm_core)
    is_punct = not is_letter and not (b >= 48 and b <= 57)
      and b > 32 and b < 127
  else
    -- 近似:非 ASCII 视为字母;有大小写区分的按 tolower/toupper 判断
    is_letter = true
    is_upper = lower ~= upper and upper == c
    is_punct = false
  end

  return setmetatable({
    normal = normal,
    base = base,
    folded = lower,
    swapped = (normal == lower) and upper or lower,
    is_base = base == normal,
    is_letter = is_letter,
    is_punct = is_punct,
    is_upper = is_upper,
  }, Char)
end

-- 对应 Character::EqualsBase(case-sensitive 的 base 比较)
function M.equals_base(a, b)
  return a.base == b.base
end

-- 对应 Character::EqualsIgnoreCase
function M.equals_ignore_case(a, b)
  return a.folded == b.folded
end

-- 对应 Character::MatchesSmart:
--   - e 匹配 e、é、E、É
--   - E 匹配 E、É,但不匹配 e、é
--   - é 匹配 é、É,但不匹配 e、E
--   - É 只匹配 É
function M.matches_smart(query_char, cand_char)
  if query_char.is_base and query_char.base == cand_char.base
      and (not query_char.is_upper or cand_char.is_upper) then
    return true
  end
  if not query_char.is_upper and query_char.folded == cand_char.folded then
    return true
  end
  return query_char.normal == cand_char.normal
end

-- 文本 -> Char 对象数组
function M.to_chars(text)
  local chars = {}
  for c in M.iter_chars(text) do
    chars[#chars + 1] = M.new(c)
  end
  return chars
end

return M

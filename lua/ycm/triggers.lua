-- 语义触发表,对照 ycmd/completers/completer_utils.py 的 DEFAULT_FILETYPE_TRIGGERS
-- 普通字符串 = 光标前文本的后缀匹配;'re!' 前缀 = Vim 正则,须匹配到行尾
local options = require('ycm.options')

local M = {}

local DEFAULT_FILETYPE_TRIGGERS = {
  c = { '->', '.' },
  objc = { '->', '.', 're!\\[[_a-zA-Z]+\\w*\\s', 're!^\\s*[^\\W\\d]\\w*\\s',
    're!\\[.*\\]\\s' },
  ocaml = { '.', '#' },
  cpp = { '->', '.', '::' },
  perl = { '->' },
  php = { '->', '::' },
  ruby = { '.', '::' },
  rust = { '.', '::' },
  cs = { '->', '.', '::' },
  java = { '.', '::' },
}

-- 共享同一组触发器的 filetype
local alias_groups = {
  { fts = { 'cuda', 'objcpp' }, trig = DEFAULT_FILETYPE_TRIGGERS.cpp },
  { fts = { 'objcpp' }, trig = DEFAULT_FILETYPE_TRIGGERS.objc },
  {
    fts = { 'd', 'elixir', 'go', 'gdscript', 'groovy', 'julia', 'perl6',
      'python', 'scala', 'vb', 'javascript', 'javascriptreact',
      'typescript', 'typescriptreact' },
    trig = { '.' },
  },
}
for _, g in ipairs(alias_groups) do
  for _, ft in ipairs(g.fts) do
    DEFAULT_FILETYPE_TRIGGERS[ft] = g.trig
  end
end

-- 光标前文本是否命中 filetype 的语义触发器
function M.matches(ft, line_before_cursor)
  local user = options.get().semantic_triggers
  local triggers = user[ft] or DEFAULT_FILETYPE_TRIGGERS[ft]
  if not triggers then
    return false
  end
  for _, trig in ipairs(triggers) do
    if trig:sub(1, 3) == 're!' then
      -- ycmd 用 Python 正则;用 very magic 的 Vim 正则近似(\w/\s/+/[] 语义一致)
      local re = vim.regex('\\v' .. trig:sub(4))
      local s, e = re:match_str(line_before_cursor)
      if s and e == #line_before_cursor then
        return true
      end
    elseif #line_before_cursor >= #trig
        and line_before_cursor:sub(-#trig) == trig then
      return true
    end
  end
  return false
end

return M

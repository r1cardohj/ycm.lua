-- 快速冒烟测试:nvim --headless -l tests/smoke.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local failures = 0
local function eq(actual, expected, name)
  if not vim.deep_equal(actual, expected) then
    failures = failures + 1
    print(('FAIL %s\n  expected: %s\n  actual:   %s')
      :format(name, vim.inspect(expected), vim.inspect(actual)))
  else
    print('ok   ' .. name)
  end
end

local char = require('ycm.char')
local match = require('ycm.match')
local ident = require('ycm.ident')
local triggers = require('ycm.triggers')

-- ---- smart case 匹配(Character::MatchesSmart) ----
local e = char.new('e')
local E = char.new('E')
eq(char.matches_smart(e, char.new('E')), true, '小写 query 匹配大写候选')
eq(char.matches_smart(E, char.new('e')), false, '大写 query 不匹配小写候选')
eq(char.matches_smart(e, char.new('é')), true, 'smart base: e 匹配 é')
eq(char.matches_smart(char.new('É'), char.new('e')), false, 'É 不匹配 e')

-- ---- 子序列匹配(Candidate::QueryMatchResult) ----
eq(#match.filter_and_sort({ 'FooBar' }, 'fb', 10), 1, '子序列 fb 匹配 FooBar')
eq(#match.filter_and_sort({ 'FooBar' }, 'fB', 10), 1, 'smart case fB 匹配 FooBar')
eq(#match.filter_and_sort({ 'FooBar' }, 'FB', 10), 1, 'FB 匹配 FooBar(词边界匹配)')
eq(#match.filter_and_sort({ 'FooBar' }, 'brf', 10), 0, '乱序不匹配')

-- ---- 排序(Result::operator<) ----
eq(match.filter_and_sort({ 'foobar', 'Foobar' }, 'foo', 10),
  { 'foobar', 'Foobar' }, '全小写候选优先')
eq(match.filter_and_sort({ 'xfoo', 'foo' }, 'foo', 10),
  { 'foo', 'xfoo' }, '前缀匹配优先')
eq(match.filter_and_sort({ 'fo', 'foo' }, 'fo', 10),
  { 'fo', 'foo' }, '短候选优先')
eq(match.filter_and_sort({ 'foobar', 'foo_bar' }, 'fb', 10)[1],
  'foo_bar', 'wb 全匹配多者优先(foo_bar 边界 f/b 全匹配)')
eq(match.filter_and_sort({ 'FooBarBazQux', 'FooBar' }, 'fb', 10)[1],
  'FooBar', 'wb 全匹配时边界字符少者优先')

-- ---- 注释/字符串剔除(identifier_utils.py) ----
local words = ident.identifiers_from_text([[
int real_var;
// int commented_var;
/* int blocked_var; */
char* s = "string_var";
]], 'c')
eq(words.real_var, true, '收集正常代码中的标识符')
eq(words.commented_var, nil, '行注释中的标识符不收集')
eq(words.blocked_var, nil, '块注释中的标识符不收集')
eq(words.string_var, nil, '字符串中的标识符不收集')

-- ---- treesitter 剔除(特性1):有 parser 时走 @comment/@string capture ----
local tsbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(tsbuf)
vim.bo[tsbuf].filetype = 'lua'
vim.api.nvim_buf_set_lines(tsbuf, 0, -1, false, {
  'local ts_real = 1',
  '-- local ts_commented = 2',
  '--[[', 'local ts_blocked = 3', ']]',
  'local ts_str = "ts_string_var"',
})
local ids = require('ycm.sources.identifiers')
ids.reparse_buffer(tsbuf, 'lua')
local tswords = ids.db.lua[tsbuf].words
eq(tswords.ts_real, true, 'treesitter: 收集正常标识符')
eq(tswords.ts_commented, nil, 'treesitter: 行注释剔除')
eq(tswords.ts_blocked, nil, 'treesitter: 块注释剔除(scanner 做不到)')
eq(tswords.ts_string_var, nil, 'treesitter: 字符串剔除')

-- 无 parser 的 filetype:回退手写 scanner
local rawbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(rawbuf)
vim.bo[rawbuf].filetype = 'notrealft'
vim.api.nvim_buf_set_lines(rawbuf, 0, -1, false, {
  'raw_real = 1', '# raw_commented = 2', 'raw_s = "raw_string_var"',
})
ids.reparse_buffer(rawbuf, 'notrealft')
local rawwords = ids.db.notrealft[rawbuf].words
eq(rawwords.raw_real, true, 'fallback: 收集正常标识符')
eq(rawwords.raw_commented, nil, 'fallback: scanner 剔除注释')
eq(rawwords.raw_string_var, nil, 'fallback: scanner 剔除字符串')
vim.api.nvim_buf_delete(tsbuf, { force = true })
vim.api.nvim_buf_delete(rawbuf, { force = true })

-- ---- 关键字播种(特性2):从 highlights.scm 字面量提取 ----
local kws = require('ycm.ts').keywords_for_filetype('lua')
eq(kws ~= nil and kws['function'] == true, true, '播种: lua 提取到 function')
eq(kws ~= nil and kws['if'] == true, true, '播种: lua 提取到 if')
eq(kws ~= nil and kws['while'] == true, true, '播种: lua 提取到 while')
eq(require('ycm.ts').keywords_for_filetype('notrealft'), nil,
  '播种: 无 parser 的语言返回 nil(静默跳过)')
-- 播种进入词库并可被补全收集
ids.ensure_seeded('lua')
eq(ids.db.lua['__keywords__'] ~= nil, true, '播种: 写入 __keywords__ 伪条目')
local seeded = ids.collect('whil', 'lua')
eq(seeded[1], 'while', '播种: 输入 whil 补出 while')

-- ---- 上下文感知路径补全(特性3) ----
local ts_mod = require('ycm.ts')
local path = require('ycm.sources.path')
local pbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(pbuf)
vim.bo[pbuf].filetype = 'lua'
vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { 'require("ut ")', 'local s = "ut "' })
vim.api.nvim_win_set_cursor(0, { 1, 11 }) -- require("ut| ")
eq(ts_mod.in_import_string(pbuf), true, '上下文: require 字符串内为 true')
vim.api.nvim_win_set_cursor(0, { 2, 11 }) -- local s = "ut| "
eq(ts_mod.in_import_string(pbuf), false, '上下文: 普通字符串内为 false')

-- 无 parser: 返回 nil(走 fallback,不放宽)
local nbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(nbuf)
vim.bo[nbuf].filetype = 'notrealft'
vim.api.nvim_buf_set_lines(nbuf, 0, -1, false, { 'require("ut ")' })
vim.api.nvim_win_set_cursor(0, { 1, 11 })
eq(ts_mod.in_import_string(nbuf), nil, '上下文: 无 parser 返回 nil')

-- relaxed 路径补全:临时目录下的裸 token
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, 'p')
vim.fn.writefile({}, tmpdir .. '/util_alpha.lua')
vim.fn.mkdir(tmpdir .. '/util_dir')
local fbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(fbuf, tmpdir .. '/main.lua')
vim.api.nvim_set_current_buf(fbuf)
vim.bo[fbuf].filetype = 'lua'
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'require("ut ' })
vim.api.nvim_win_set_cursor(0, { 1, 11 })
local items = path.collect(fbuf, 'lua', true)
local words = vim.tbl_map(function(i) return i.word end, items or {})
table.sort(words)
eq(words, { 'util_alpha.lua', 'util_dir/' }, 'relaxed: 裸 token 列出目录内容')
eq(path.collect(fbuf, 'lua', false), nil, '非 relaxed: 无 / 的 token 不触发')
vim.fn.delete(tmpdir, 'rf')

-- ---- query 计算(StartOfLongestIdentifierEndingAtIndex) ----
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'lua'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local foo_bar = fbb ' })
vim.api.nvim_win_set_cursor(0, { 1, 19 }) -- 0-based,光标在 fbb 后的空格上
local start_col, query = ident.query_at_cursor('lua')
eq(start_col, 17, 'query 起点为 fbb 开头')
eq(query, 'fbb', 'query = 光标前最长标识符')

-- 标识符完成检测(CurrentIdentifierFinished):光标前一个是非标识符字符、
-- 再前一个是标识符结尾
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'apple_count  ' })
vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- 0-based,光标在第二个空格上
local finished, word = ident.identifier_finished_before_cursor('lua')
eq(finished, true, 'apple_count 后输入空格视为标识符完成')
eq(word, 'apple_count', '提取刚完成的标识符')
vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- 光标在 apple 中间/末尾
eq((ident.identifier_finished_before_cursor('lua')), false, '标识符输入中不算完成')

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foo. bar' })
vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- 0-based,光标在 '.' 之后
eq(select(2, ident.query_at_cursor('lua')), '', '点后无标识符时 query 为空')

-- ---- 语义触发(DEFAULT_FILETYPE_TRIGGERS) ----
eq(triggers.matches('cpp', 'obj->'), true, 'cpp -> 触发')
eq(triggers.matches('cpp', 'ns::'), true, 'cpp :: 触发')
eq(triggers.matches('python', 'obj.'), true, 'python . 触发')
eq(triggers.matches('python', 'obj'), false, '无触发字符不触发')

-- ---- 集成:在子 nvim 实例(RPC 驱动,真实主循环)中模拟输入触发补全菜单 ----
local sock = vim.fn.tempname()
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local job = vim.fn.jobstart({ 'nvim', '--headless', '--clean', '--listen', sock })
assert(vim.wait(5000, function() return vim.uv.fs_stat(sock) ~= nil end),
  '子 nvim 实例启动失败')
local chan = vim.fn.sockconnect('pipe', sock, { rpc = true })
local function child(code, ...)
  return vim.rpcrequest(chan, 'nvim_exec_lua', code, { ... })
end
child(('vim.opt.rtp:prepend(%q); require("ycm").setup({ use_lsp = false })')
  :format(plugin_dir))
child([[vim.cmd.enew()
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false,
  { 'local apple_count = 1', 'local apple_size = 2', 'app' })
vim.bo[buf].filetype = 'lua'
vim.api.nvim_win_set_cursor(0, { 3, 3 })]])
vim.rpcrequest(chan, 'nvim_input', 'Al') -- 行末插入 'l' -> "appl"
local items = {}
vim.wait(5000, function()
  items = child([[if vim.fn.pumvisible() == 1 then
    return vim.tbl_map(function(i) return i.word end,
      vim.fn.complete_info({ 'items' }).items)
  end
  return {}]])
  return #items > 0
end)
-- 按 Result.cpp 比较链:两者首字符/前缀/wb 匹配/下标和均相同,
-- 短候选优先,故 apple_size 在 apple_count 之前(与真实 YCM 一致)
eq(items, { 'apple_size', 'apple_count' },
  '输入 appl 后菜单按 YCM 规则排序')

-- 回归:菜单可见时继续输入必须重新过滤(CompleteChanged 不得重置
-- last_char_inserted_by_user,否则 TextChangedP 被跳过)
child([[local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false,
  { 'Person', 'import', 'print(self.name)', '' })
vim.api.nvim_win_set_cursor(0, { 4, 0 })
require('ycm.sources.identifiers').reparse_buffer(buf, vim.bo[buf].filetype)]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>ipr') -- 回到 normal 再插入两字符弹出菜单
local stuck = {}
vim.wait(5000, function()
  stuck = child([[if vim.fn.pumvisible() == 1 then
    return vim.tbl_map(function(i) return i.word end,
      vim.fn.complete_info({ 'items' }).items)
  end
  return {}]])
  return #stuck > 0
end)
eq(stuck, { 'print', 'Person', 'import' }, 'query=pr 时的候选与排序')
vim.rpcrequest(chan, 'nvim_input', 'int') -- 菜单可见时继续输入
local refiltered = stuck
vim.wait(5000, function()
  refiltered = child([[return vim.tbl_map(function(i) return i.word end,
    vim.fn.complete_info({ 'items' }).items)]])
  return #refiltered ~= #stuck
end)
eq(refiltered, { 'print' }, 'query=print 时只剩 print(菜单随输入重过滤)')

-- ---- 语义补全门控:对照 ycmd Completer.ShouldUseNowInner,LSP 只在 ----
-- ---- 触发字符/手动触发时参与,并在会话内(start_col 不变)延续       ----
child([[require('ycm').setup({ use_lsp = true })
local lsp = require('ycm.sources.lsp')
lsp.has_clients = function() return true end
lsp.clients = function() return { { offset_encoding = 'utf-16' } } end
_G.lsp_calls = {}
lsp.request = function(_, trigger_char, cb)
  table.insert(_G.lsp_calls, trigger_char or false)
  local function it(w)
    return { match_text = w,
      item = { word = w, menu = 'lsp', equal = 1, dup = 1, empty = 1 } }
  end
  cb({ it('name'), it('nickname') })
end
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'python' -- 前一段是 lua,没有 '.' 触发器
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'self.name', 'seldom', '' })
require('ycm.sources.identifiers').reparse_buffer(buf, vim.bo[buf].filetype)
vim.api.nvim_win_set_cursor(0, { 3, 0 })]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>ise')
vim.wait(5000, function()
  return child([[return vim.fn.pumvisible()]]) == 1
end)
eq(child([[return #_G.lsp_calls]]), 0,
  '无触发字符时不请求 LSP(query 达最小长度也不请求)')
local id_items = child([[return vim.tbl_map(function(i)
  return i.word .. i.menu end, vim.fn.complete_info({ 'items' }).items)]])
eq(id_items, { 'self[ID]', 'seldom[ID]' }, '普通输入只给 [ID] 候选')
-- 输入触发字符 '.' -> LSP 参与(排他)
vim.rpcrequest(chan, 'nvim_input', '<Esc>A.')
vim.wait(5000, function() return child([[return #_G.lsp_calls]]) > 0 end)
local sem_items = {}
vim.wait(5000, function()
  sem_items = child([[return vim.tbl_map(function(i)
    return i.word end, vim.fn.complete_info({ 'items' }).items)]])
  return #sem_items > 0
end)
eq(child([=[return _G.lsp_calls[1]]=]), '.', '触发字符上报给 LSP')
eq(sem_items, { 'name', 'nickname' }, '触发后语义补全排他展示')
-- 会话延续:继续输入 n,同一 start_col,LSP 继续参与
vim.rpcrequest(chan, 'nvim_input', 'n')
vim.wait(5000, function() return child([[return #_G.lsp_calls]]) > 1 end)
local cont_items = {}
vim.wait(5000, function()
  cont_items = child([[return vim.tbl_map(function(i)
    return i.word end, vim.fn.complete_info({ 'items' }).items)]])
  return vim.deep_equal(cont_items, { 'name', 'nickname' })
end)
eq(cont_items, { 'name', 'nickname' }, '会话内继续输入仍走语义补全')

-- ---- Auto-import:CompleteDone 时应用 additionalTextEdits ----
child([[local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1', '' })
vim.api.nvim_win_set_cursor(0, { 2, 0 })]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>i')
child([[local edit = {
  range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } },
  newText = 'from typing import Self\n',
}
local ud = vim.json.encode({ ycm_lua = true, edits = { edit } })
vim.fn.complete(1, { { word = 'Self', abbr = 'Self', menu = 'v Auto-import',
  equal = 1, dup = 1, empty = 1, user_data = ud } })]])
vim.rpcrequest(chan, 'nvim_input', '<C-y>')
local ai_lines = {}
vim.wait(5000, function()
  ai_lines = child([[return vim.api.nvim_buf_get_lines(0, 0, -1, false)]])
  return ai_lines[1] == 'from typing import Self'
end)
eq(ai_lines, { 'from typing import Self', 'x = 1', 'Self' },
  '选中 Auto-import 候选后自动插入 import 语句')
eq(child([[return vim.api.nvim_win_get_cursor(0)]]), { 3, 4 },
  '应用 additionalTextEdits 后光标位置正确')

-- ---- 成员学习(特性4):无 LSP 时 self. 出已知成员 ----
child([[require('ycm').setup({ use_lsp = false })
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'lua'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'self.name = 1', 'self.age = 2', 'other.name = 3', ''
})
vim.api.nvim_win_set_cursor(0, { 4, 0 })]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>iself.')
local mem_items = {}
vim.wait(5000, function()
  mem_items = child([[if vim.fn.pumvisible() == 1 then
    return vim.tbl_map(function(i) return i.word .. i.menu end,
      vim.fn.complete_info({ 'items' }).items)
  end
  return {}]])
  return #mem_items > 0
end)
eq(mem_items, { 'age[M]', 'name[M]' },
  '成员学习: 无 LSP 时 self. 出已知成员(不混入 other 的成员)')
-- 继续输入 n 过滤
vim.rpcrequest(chan, 'nvim_input', 'n')
vim.wait(5000, function()
  mem_items = child([[return vim.tbl_map(function(i) return i.word .. i.menu end,
    vim.fn.complete_info({ 'items' }).items)]])
  return vim.deep_equal(mem_items, { 'name[M]' })
end)
eq(mem_items, { 'name[M]' }, '成员学习: self.n 过滤为 name')

-- ---- 回归:注释内不触发补全(complete_in_comments = false) ----
-- 行尾光标恰好在 comment 节点开边界外,检测必须落在前一个字符上
child([[local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local self_hint = 1', '', '' })
require('ycm.sources.identifiers').reparse_buffer(buf, 'lua')
vim.api.nvim_win_set_cursor(0, { 2, 0 })]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>i-- se')
vim.wait(1500, function() return false end)
eq(child([[return vim.fn.pumvisible()]]), 0, '注释内输入不弹菜单')
-- 对照:正常代码里输入要弹
vim.rpcrequest(chan, 'nvim_input', '<Esc>')
child([[vim.api.nvim_win_set_cursor(0, { 3, 0 })]])
vim.rpcrequest(chan, 'nvim_input', 'ise')
local code_items = {}
vim.wait(5000, function()
  code_items = child([[if vim.fn.pumvisible() == 1 then
    return vim.tbl_map(function(i) return i.word end,
      vim.fn.complete_info({ 'items' }).items)
  end
  return {}]])
  return #code_items > 0
end)
-- 注意:else/elseif 来自特性2播种的 lua 关键字(subsequence 'se' 命中)
eq(code_items, { 'self_hint', 'else', 'elseif' }, '正常代码内输入弹菜单')

-- ---- 手动语义触发(对照 g:ycm_key_invoke_completion = <C-Space>) ----
child([[require('ycm').setup({ use_lsp = true })
local lsp = require('ycm.sources.lsp')
lsp.has_clients = function() return true end
lsp.clients = function() return { { offset_encoding = 'utf-16' } } end
lsp.request = function(_, _, cb)
  local function it(w)
    return { match_text = w,
      item = { word = w, menu = 'lsp', equal = 1, dup = 1, empty = 1 } }
  end
  cb({ it('name'), it('nickname') })
end
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'lua'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })]])
vim.rpcrequest(chan, 'nvim_input', '<Esc>in') -- 只敲 1 个字符,不到自动触发阈值
vim.wait(1000, function() return false end)
eq(child([[return vim.fn.pumvisible()]]), 0,
  '单字符不自动触发(也不该有语义补全)')
vim.rpcrequest(chan, 'nvim_input', '<C-Space>') -- 手动唤起语义补全
local manual_items = {}
vim.wait(5000, function()
  manual_items = child([[if vim.fn.pumvisible() == 1 then
    return vim.tbl_map(function(i) return i.word end,
      vim.fn.complete_info({ 'items' }).items)
  end
  return {}]])
  return #manual_items > 0
end)
eq(manual_items, { 'name', 'nickname' }, '<C-Space> 手动触发语义补全')
vim.rpcnotify(chan, 'nvim_command', 'qa!')
vim.fn.jobstop(job)

print(('\n%d failures'):format(failures))
os.exit(failures == 0 and 0 or 1)

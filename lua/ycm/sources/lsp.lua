-- LSP 语义补全源:对应 YCM 的 ycmd filetype completer(clangd 等)。
-- 用 Neovim 内置 LSP client 请求 textDocument/completion,
-- 候选仍走 YCM 的子序列过滤 + 排序(YCM 对语义候选同样做 FilterAndSortCandidates)。
local match = require('ycm.match')
local options = require('ycm.options')

local M = {}

-- LSP CompletionItemKind -> complete-items 的单字母 kind
local KIND_LETTER = {
  [1] = 't', -- Text
  [2] = 'f', -- Method
  [3] = 'f', -- Function
  [4] = 'f', -- Constructor
  [5] = 'f', -- Field
  [6] = 'v', -- Variable
  [7] = 'c', -- Class
  [8] = 'c', -- Interface
  [9] = 'm', -- Module
  [10] = 'p', -- Property
  [11] = 'v', -- Unit
  [12] = 'v', -- Value
  [13] = 'e', -- Enum
  [14] = 'k', -- Keyword
  [15] = 's', -- Snippet
  [16] = 'c', -- Color
  [17] = 'f', -- File
  [18] = 'r', -- Reference
  [19] = 'f', -- Folder
  [20] = 'e', -- EnumMember
  [21] = 'c', -- Constant
  [22] = 'c', -- Struct
  [23] = 'e', -- Event
  [24] = 'f', -- Operator
  [25] = 't', -- TypeParameter
}

function M.clients(bufnr)
  return vim.lsp.get_clients({
    bufnr = bufnr,
    method = 'textDocument/completion',
  })
end

function M.has_clients(bufnr)
  return #M.clients(bufnr) > 0
end

-- 剥离 snippet 语法为纯文本:${1:foo} -> foo,$1/$0 -> ''
local function strip_snippet(s)
  local prev
  repeat
    prev = s
    s = s:gsub('%${%d+:([^{}]*)}', '%1')
  until s == prev
  s = s:gsub('%${%d+}', '')
  s = s:gsub('%$%d+', '')
  s = s:gsub('\\(.)', '%1')
  return s
end
M.strip_snippet = strip_snippet

-- 判断 LSP item 的匹配/插入文本
local function item_texts(item)
  local insert = item.insertText
  if item.textEdit and item.textEdit.newText then
    insert = item.textEdit.newText
  end
  insert = insert or item.label
  local is_snippet = item.insertTextFormat == 2
  local match_text = item.filterText or item.label or insert
  if is_snippet then
    -- 匹配用纯文本;插入文本保留 snippet 供 CompleteDone 展开(若开启)
    match_text = strip_snippet(match_text)
  end
  local word = is_snippet and strip_snippet(insert) or insert
  return match_text, word, is_snippet and insert or nil
end

-- 发起补全请求;trigger_character 为命中的语义触发字符(可为 nil)。
-- cb(converted_items) 聚合所有 client 的结果后被调用一次。
-- converted_items: { match_text = <参与 YCM 匹配的文本>, item = <complete-item> }
function M.request(bufnr, trigger_character, cb)
  local clients = M.clients(bufnr)
  if #clients == 0 then
    cb({})
    return
  end

  local ok, params = pcall(vim.lsp.util.make_position_params, 0,
    clients[1].offset_encoding)
  if not ok then
    params = vim.lsp.util.make_position_params(0)
  end
  -- CompletionContext:仅当触发字符确实被某 client 声明为 triggerCharacter
  -- 时才以 TriggerCharacter(2) 上报
  local context = { triggerKind = 1 }
  if trigger_character then
    for _, client in ipairs(clients) do
      local cp = client.server_capabilities
        and client.server_capabilities.completionProvider
      local tcs = cp and cp.triggerCharacters or {}
      if vim.tbl_contains(tcs, trigger_character) then
        context = { triggerKind = 2, triggerCharacter = trigger_character }
        break
      end
    end
  end
  params.context = context

  vim.lsp.buf_request_all(bufnr, 'textDocument/completion', params,
    function(results)
      local converted = {}
      for client_id, resp in pairs(results) do
        local items = resp.result
        if items then
          if items.items then
            items = items.items -- CompletionList
          end
          for _, item in ipairs(items) do
            if type(item) == 'table' and item.label then
              local match_text, word, snippet = item_texts(item)
              local entry = {
                word = word,
                abbr = item.label ~= word and item.label or nil,
                menu = item.detail or '',
                kind = KIND_LETTER[item.kind or 1] or 'v',
                equal = 1, -- 禁用 Vim 自身过滤(同 YCM)
                dup = 1,
                empty = 1,
              }
              -- CompleteDone 后处理:snippet 展开 / additionalTextEdits
              -- (自动 import,对应 YCM 的 FixIt chunks 应用)
              local ud = {}
              if snippet then
                ud.snippet = snippet
              end
              if type(item.additionalTextEdits) == 'table'
                  and #item.additionalTextEdits > 0 then
                ud.edits = item.additionalTextEdits
                ud.client_id = client_id
              end
              if next(ud) then
                ud.ycm_lua = true
                entry.user_data = vim.json.encode(ud)
              end
              converted[#converted + 1] = {
                match_text = match_text,
                item = entry,
              }
            end
          end
        end
      end
      cb(converted)
    end)
end

-- 对 LSP 结果做 YCM 式过滤排序(对照 Completer.FilterAndSortCandidates),
-- 返回 complete() 可用的 item 数组
function M.filter_and_sort(converted, query)
  local words = {}
  for i, c in ipairs(converted) do
    words[i] = c.match_text
  end
  -- match.filter_and_sort 返回排序后的文本;建立文本 -> entry 的映射回填
  local sorted = match.filter_and_sort(
    words, query, options.get().max_num_candidates)
  local by_text = {}
  for _, c in ipairs(converted) do
    local list = by_text[c.match_text]
    if list then
      list[#list + 1] = c
    else
      by_text[c.match_text] = { c }
    end
  end
  local out = {}
  local seen = {}
  for _, text in ipairs(sorted) do
    if not seen[text] then
      seen[text] = true
      local entry = table.remove(by_text[text] or {}, 1)
      if entry then
        out[#out + 1] = entry.item
      end
    end
  end
  return out
end

-- 应用 additionalTextEdits(自动 import 等;对应 YCM OnCompleteDone 的
-- FixIt chunks 应用)。用 extmark 记录光标以抵抗编辑引起的位移。
local function apply_additional_edits(bufnr, edits, client_id)
  local enc = 'utf-16'
  local client = client_id and vim.lsp.get_client_by_id(client_id)
  if client and client.offset_encoding then
    enc = client.offset_encoding
  end
  local ns = vim.api.nvim_create_namespace('ycm_lua_cursor')
  local cur = vim.api.nvim_win_get_cursor(0)
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, cur[1] - 1, cur[2], {})
  vim.lsp.util.apply_text_edits(edits, bufnr, enc)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
  vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
  if pos and pos[1] then
    pcall(vim.api.nvim_win_set_cursor, 0, { pos[1] + 1, pos[2] })
  end
end

-- CompleteDone 处理:应用 additionalTextEdits,可选展开 snippet
-- (snippet 默认关;YCM 原生不展开,靠 UltiSnips 集成)
function M.on_complete_done()
  local completed = vim.v.completed_item
  local ud = completed and completed.user_data
  if type(ud) ~= 'string' or ud == '' then
    return
  end
  local ok, data = pcall(vim.json.decode, ud)
  if not ok or type(data) ~= 'table' or not data.ycm_lua then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if data.edits then
    apply_additional_edits(bufnr, data.edits, data.client_id)
  end
  if data.snippet and options.get().lsp_snippet_expand and vim.snippet then
    local word = completed.word
    if word and word ~= '' then
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local n = #word
      if line:sub(col - n + 1, col) == word then
        vim.api.nvim_buf_set_text(0, row - 1, col - n, row - 1, col, { '' })
        vim.snippet.expand(data.snippet)
      end
    end
  end
end

return M

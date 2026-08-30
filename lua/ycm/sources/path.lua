-- 文件路径补全源:对应 ycmd 的 filename_completer.py 的简化版。
-- 光标前的 token 含 '/' 时触发,补全目录内容(目录名带 '/' 后缀)。
local options = require('ycm.options')

local M = {}

-- 从光标前文本提取路径 token;返回 (token, start_col) 或 nil。
-- relaxed 为 true 时(treesitter 判定处于 import/require 字符串内)
-- 允许不含 '/' 的裸 token。
local function path_token_before_cursor(relaxed)
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col('.')
  local before = line:sub(1, col - 1)
  local token = before:match('([%w%._~%-%/]+)$')
  if not token or token == '' then
    return nil
  end
  if not relaxed and not token:find('/') then
    return nil
  end
  return token, col - #token
end

local function expand_dir(dir, bufnr)
  if dir:sub(1, 1) == '~' then
    dir = vim.fn.expand(dir)
  elseif dir:sub(1, 1) ~= '/' then
    if options.get().filepath_completion_use_working_dir then
      dir = vim.fn.getcwd() .. '/' .. dir
    else
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      local base = bufname ~= '' and vim.fn.fnamemodify(bufname, ':h')
        or vim.fn.getcwd()
      dir = base .. '/' .. dir
    end
  end
  return dir
end

-- 返回 (items, start_col);items 中 word 为路径最后一段(目录带 '/')。
-- relaxed 见 path_token_before_cursor。
function M.collect(bufnr, ft, relaxed)
  local opts = options.get()
  if not opts.use_filepath_completion or opts.filepath_blacklist[ft] then
    return nil
  end

  local token, token_start = path_token_before_cursor(relaxed)
  if not token then
    return nil
  end

  -- 拆分目录部分与待补全前缀(裸 token 没有目录部分)
  local dir_part, base = token:match('^(.*%/)([^%/]*)$')
  if not dir_part then
    dir_part, base = '', token
  end
  local dir = expand_dir(dir_part, bufnr)

  local ok, entries = pcall(vim.fn.glob, dir .. '/' .. base .. '*', true, true)
  if not ok or type(entries) ~= 'table' then
    return nil
  end

  local items = {}
  for i, p in ipairs(entries) do
    if i > opts.max_num_candidates then
      break
    end
    local name = vim.fn.fnamemodify(p, ':t')
    if name ~= '' and name:sub(1, 1) ~= '.' then
      local is_dir = vim.fn.isdirectory(p) == 1
      items[#items + 1] = {
        word = name .. (is_dir and '/' or ''),
        abbr = name .. (is_dir and '/' or ''),
        menu = '[path]',
        kind = 'f',
        equal = 1,
        dup = 1,
        empty = 1,
      }
    end
  end

  if #items == 0 then
    return nil
  end
  -- 补全起点在最后一个 '/' 之后
  return items, token_start + #dir_part
end

return M

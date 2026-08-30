-- 调试日志:内存 ring buffer,:YcmLuaDebug 导出到文件
local M = {}

local MAX = 300
M.entries = {}

function M.add(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then
    msg = tostring(fmt)
  end
  M.entries[#M.entries + 1] = string.format('%.3f %s',
    vim.loop.hrtime() / 1e9, msg)
  if #M.entries > MAX then
    table.remove(M.entries, 1)
  end
end

function M.dump(path)
  path = path or '/tmp/ycm_lua_debug.log'
  vim.fn.writefile(M.entries, path)
  return path
end

return M

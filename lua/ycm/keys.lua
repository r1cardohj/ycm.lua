-- 键位映射,对照 autoload/youcompleteme.vim 的 s:SetUpKeyMappings:
--   select:   pumvisible() ? <C-n> : 原键(默认 <TAB>、<Down>)
--   previous: pumvisible() ? <C-p> : 原键(默认 <S-TAB>、<Up>)
--   stop:     pumvisible() 时 <C-y> 接受并标记 completion_stopped,
--             防止 TextChangedI 重新打开菜单(默认 <C-y>)
--   invoke:   手动触发语义补全(默认 <C-Space>)
local M = {}

local installed = {}

local function unmap(key)
  pcall(vim.keymap.del, 'i', key)
end

function M.setup(opts, callbacks)
  for _, key in ipairs(installed) do
    unmap(key)
  end
  installed = {}

  local function map(key, fn)
    vim.keymap.set('i', key, fn, { expr = true, silent = true })
    installed[#installed + 1] = key
  end

  for _, key in ipairs(opts.key_list_select_completion) do
    map(key, function()
      if vim.fn.pumvisible() == 1 then
        return '<C-n>'
      end
      return key
    end)
  end

  for _, key in ipairs(opts.key_list_previous_completion) do
    map(key, function()
      if vim.fn.pumvisible() == 1 then
        return '<C-p>'
      end
      return key
    end)
  end

  for _, key in ipairs(opts.key_list_stop_completion) do
    map(key, function()
      if vim.fn.pumvisible() == 1 then
        callbacks.on_stop()
        return '<C-y>'
      end
      return key
    end)
  end

  if opts.key_invoke_completion and opts.key_invoke_completion ~= '' then
    map(opts.key_invoke_completion, function()
      callbacks.on_invoke()
      return ''
    end)
    -- 终端里 <C-Space> 常被传为 <Nul>
    if opts.key_invoke_completion == '<C-Space>' then
      map('<Nul>', function()
        callbacks.on_invoke()
        return ''
      end)
    end
  end
end

function M.teardown()
  for _, key in ipairs(installed) do
    unmap(key)
  end
  installed = {}
end

return M

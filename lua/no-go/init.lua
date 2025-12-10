local M = {}

local config = require("no-go.config")
local fold = require("no-go.fold")
local utils = require("no-go.utils")

-- Track plugin initialization
M.initialized = false

-- Autocmd group
M.augroup = nil

-- Global enabled state (controls whether folding happens at all)
M.is_globally_enabled = true

-- these vars are for tracking per buffer enabled and disabled states
M.disabled_buffers = {}

M.enabled_buffers = {}

M.keymap_buffers = {}

--- these keymaps skip over concealed lines using direct cursor movement
--- only set up when reveal_on_cursor is false!
--- @param bufnr number The buffer number
--- @param opts table The plugin configuration
local function setup_keymaps(bufnr, opts)
  if M.keymap_buffers[bufnr] then
    return
  end

  if not opts.keys then
    return
  end

  local namespace = fold.namespace

  if opts.keys.down then
    vim.keymap.set({ "n", "x", "o" }, opts.keys.down, function()
      local view = vim.fn.winsaveview()
      local lines = utils.smart_down_lines(vim.v.count1, namespace)
      if lines > 0 then
        vim.cmd("normal! " .. lines .. "j")
        local new_view = vim.fn.winsaveview()
        new_view.curswant = view.curswant
        vim.fn.winrestview(new_view)
      end
    end, { buffer = bufnr, desc = "Smart down (preserve goal column)" })
  end

  if opts.keys.up then
    vim.keymap.set({ "n", "x", "o" }, opts.keys.up, function()
      local view = vim.fn.winsaveview()
      local lines = utils.smart_up_lines(vim.v.count1, namespace)
      if lines > 0 then
        vim.cmd("normal! " .. lines .. "k")
        local new_view = vim.fn.winsaveview()
        new_view.curswant = view.curswant
        vim.fn.winrestview(new_view)
      end
    end, { buffer = bufnr, desc = "Smart up (preserve goal column)" })
  end

  if opts.keys.enter then
    vim.keymap.set({ "n", "x", "o" }, opts.keys.enter, function()
      local bufnr = vim.api.nvim_get_current_buf()
      local range = utils.find_nearest_concealed_range(
        bufnr,
        vim.fn.line(".") - 1,
        namespace,
        opts.keys.enter_search_next ~= false
      )
      if not range then
        return
      end

      local view = vim.fn.winsaveview()

      -- jump to the first concealed line of the block
      vim.api.nvim_win_set_cursor(0, { range.start_row + 1, 0 })

      -- reprocess buffer with reveal_on_cursor behavior to unhide this block
      local effective_opts = opts
      if not opts.reveal_on_cursor then
        effective_opts = vim.tbl_deep_extend("force", {}, opts, { reveal_on_cursor = true })
      end
      fold.process_buffer(bufnr, effective_opts)

      local new_view = vim.fn.winsaveview()
      new_view.curswant = view.curswant
      vim.fn.winrestview(new_view)
    end, { buffer = bufnr, desc = "Enter concealed block" })
  end

  if opts.keys.refold then
    vim.keymap.set({ "n", "x", "o" }, opts.keys.refold, function()
      local bufnr = vim.api.nvim_get_current_buf()
      local view = vim.fn.winsaveview()
      fold.process_buffer(bufnr, opts)
      local new_view = vim.fn.winsaveview()
      new_view.curswant = view.curswant
      vim.fn.winrestview(new_view)
    end, { buffer = bufnr, desc = "Refold concealed regions" })
  end

  M.keymap_buffers[bufnr] = true
end

--- Setup the plugin with user configuration
--- @param user_config table|nil Optional user configuration to override defaults
function M.setup(user_config)
  local opts = config.setup(user_config)

  M.is_globally_enabled = opts.enabled

  M.augroup = vim.api.nvim_create_augroup("NoGo", { clear = true })

  vim.api.nvim_create_autocmd(opts.update_events, {
    group = M.augroup,
    pattern = "*.go",
    callback = function(args)
      setup_keymaps(args.buf, opts)

      if M.disabled_buffers[args.buf] then
        return
      end

      -- skip if globally disabled AND buffer is not explicitly enabled
      if not M.is_globally_enabled and not M.enabled_buffers[args.buf] then
        return
      end

      -- debounce updates slightly to avoid excessive processing
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(args.buf) and not M.disabled_buffers[args.buf] then
          -- process if globally enabled OR buffer is explicitly enabled
          if M.is_globally_enabled or M.enabled_buffers[args.buf] then
            fold.process_buffer(args.buf, opts)
          end
        end
      end, 10)
    end,
  })

  -- Setup CursorMoved autocmd for reveal_on_cursor feature
  if opts.reveal_on_cursor then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = M.augroup,
      pattern = "*.go",
      callback = function(args)
        if M.disabled_buffers[args.buf] then
          return
        end

        -- skip if globally disabled AND buffer is not explicitly enabled
        if not M.is_globally_enabled and not M.enabled_buffers[args.buf] then
          return
        end

        -- debounce cursor movements to avoid excessive processing
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(args.buf) and not M.disabled_buffers[args.buf] then
            if M.is_globally_enabled or M.enabled_buffers[args.buf] then
              -- need to save the goal cursor
              local view = vim.fn.winsaveview()
              fold.process_buffer(args.buf, opts)
              -- and restore it here
              local new_view = vim.fn.winsaveview()
              new_view.curswant = view.curswant
              vim.fn.winrestview(new_view)
            end
          end
        end, 10)
      end,
    })
  end

  if M.is_globally_enabled then
    local current_buf = vim.api.nvim_get_current_buf()
    local ft = vim.api.nvim_get_option_value("filetype", { buf = current_buf })
    if ft == "go" then
      setup_keymaps(current_buf, opts)
      fold.process_buffer(current_buf, opts)
    end
  end

  M.initialized = true
end

--- Manually refresh the current buffer
function M.refresh()
  if not M.initialized then
    vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  fold.process_buffer(bufnr, config.options)
end

-- GLOBAL COMMANDS (affect all buffers)

--- Disable the plugin globally (all Go buffers)
function M.disable()
  if not M.initialized then
    return
  end

  -- Set global state to disabled
  M.is_globally_enabled = false

  -- Clear explicitly enabled buffers (global disable overrides all)
  M.enabled_buffers = {}

  -- Clear extmarks from all Go buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if ft == "go" then
        fold.clear_extmarks(bufnr)
      end
    end
  end
end

--- Enable the plugin globally (all Go buffers)
function M.enable()
  if not M.initialized then
    vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
    return
  end

  -- Set global state to enabled
  M.is_globally_enabled = true

  -- Refresh all visible Go buffers (excluding per-buffer disabled ones)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      if ft == "go" and not M.disabled_buffers[bufnr] then
        fold.process_buffer(bufnr, config.options)
      end
    end
  end
end

--- Toggle the plugin globally (all Go buffers)
function M.toggle()
  if not M.initialized then
    vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
    return
  end

  -- Toggle global state
  if M.is_globally_enabled then
    M.disable()
  else
    M.enable()
  end
end

-- BUFFER-SPECIFIC COMMANDS (affect only current buffer)

--- Disable the plugin for current buffer only
function M.disable_buffer()
  if not M.initialized then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Mark buffer as disabled
  M.disabled_buffers[bufnr] = true

  -- Remove from explicitly enabled buffers
  M.enabled_buffers[bufnr] = nil

  -- Clear extmarks for this buffer
  fold.clear_extmarks(bufnr)
end

--- Enable the plugin for current buffer only
function M.enable_buffer()
  if not M.initialized then
    vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Remove buffer from disabled list
  M.disabled_buffers[bufnr] = nil

  -- If globally disabled, add to explicitly enabled buffers
  if not M.is_globally_enabled then
    M.enabled_buffers[bufnr] = true
  end

  fold.process_buffer(bufnr, config.options)
end

--- Toggle the plugin for current buffer only
function M.toggle_buffer()
  if not M.initialized then
    vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- Check if buffer is currently disabled
  if M.disabled_buffers[bufnr] then
    M.enable_buffer()
  else
    M.disable_buffer()
  end
end

return M

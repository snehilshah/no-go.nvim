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

-- per-buffer enabled / disabled override sets
M.disabled_buffers = {}
M.enabled_buffers = {}
M.keymap_buffers = {}

-- Track manually revealed blocks per buffer: { [bufnr] = { [row] = true } }
M.revealed_blocks = {}

-- per-buffer debounce timers; one outstanding refresh per buffer max
local _timers = {}

--- @param bufnr number
local function buffer_is_active(bufnr)
	if M.disabled_buffers[bufnr] then
		return false
	end
	if not M.is_globally_enabled and not M.enabled_buffers[bufnr] then
		return false
	end
	return true
end

--- Schedule a single debounced process_buffer per buffer.
--- @param bufnr number
--- @param opts table
--- @param delay_ms number
local function schedule_refresh(bufnr, opts, delay_ms)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then
		return
	end

	local existing = _timers[bufnr]
	if existing then
		existing:stop()
		existing:close()
		_timers[bufnr] = nil
	end

	local timer = vim.uv.new_timer()
	if not timer then
		-- fall back to direct call if timer allocation fails
		fold.process_buffer(bufnr, opts, M.revealed_blocks[bufnr])
		return
	end
	_timers[bufnr] = timer

	timer:start(
		delay_ms,
		0,
		vim.schedule_wrap(function()
			local t = _timers[bufnr]
			if t then
				t:stop()
				t:close()
				_timers[bufnr] = nil
			end
			if vim.api.nvim_buf_is_valid(bufnr) and buffer_is_active(bufnr) then
				fold.process_buffer(bufnr, opts, M.revealed_blocks[bufnr])
			end
		end)
	)
end

--- these keymaps skip over concealed lines using direct cursor movement
--- only set up when reveal_on_cursor is false!
--- @param bufnr number The buffer number
--- @param opts table The plugin configuration
local function setup_keymaps(bufnr, opts)
	if M.keymap_buffers[bufnr] or not opts.keys then
		return
	end

	local namespace = fold.namespace

	if opts.keys.down then
		vim.keymap.set({ "n", "x", "o" }, opts.keys.down, function()
			if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then
				return "j"
			end
			local lines = utils.smart_down_lines(vim.v.count1, namespace)
			return lines > 0 and (lines .. "j") or ""
		end, { buffer = bufnr, desc = "Smart down (preserve goal column)", expr = true })
	end

	if opts.keys.up then
		vim.keymap.set({ "n", "x", "o" }, opts.keys.up, function()
			if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then
				return "k"
			end
			local lines = utils.smart_up_lines(vim.v.count1, namespace)
			return lines > 0 and (lines .. "k") or ""
		end, { buffer = bufnr, desc = "Smart up (preserve goal column)", expr = true })
	end

	if opts.keys.toggle then
		vim.keymap.set({ "n", "x", "o" }, opts.keys.toggle, function()
			local bufnr = vim.api.nvim_get_current_buf()
			local row = vim.fn.line(".") - 1 -- 0-indexed

			-- initialize tracking for this buffer if needed
			if not M.revealed_blocks[bufnr] then
				M.revealed_blocks[bufnr] = {}
			end

			local view = vim.fn.winsaveview()

			-- check if this row is a manually revealed block -> refold it
			if M.revealed_blocks[bufnr][row] then
				M.revealed_blocks[bufnr][row] = nil
				fold.process_buffer(bufnr, opts, M.revealed_blocks[bufnr])
				vim.fn.winrestview(view)
				return
			end

			-- check if cursor is on the header line of a concealed block -> reveal it
			if utils.is_on_fold_header(bufnr, row, namespace) then
				M.revealed_blocks[bufnr][row] = true
				-- reprocess with reveal_on_cursor to unhide this block
				local effective_opts = vim.tbl_deep_extend("force", {}, opts, { reveal_on_cursor = true })
				fold.process_buffer(bufnr, effective_opts, M.revealed_blocks[bufnr])
				vim.fn.winrestview(view)
				return
			end

			vim.notify("no-go.nvim: not on a concealed block", vim.log.levels.INFO)
		end, { buffer = bufnr, desc = "Toggle fold/unfold concealed block" })
	end

	M.keymap_buffers[bufnr] = true
end

--- Cleanup state for a buffer that was wiped/unloaded.
--- @param bufnr number
local function on_buf_gone(bufnr)
	local t = _timers[bufnr]
	if t then
		t:stop()
		t:close()
		_timers[bufnr] = nil
	end
	M.keymap_buffers[bufnr] = nil
	M.disabled_buffers[bufnr] = nil
	M.enabled_buffers[bufnr] = nil
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
			if not buffer_is_active(args.buf) then
				return
			end
			schedule_refresh(args.buf, opts, opts.debounce_ms or 60)
		end,
	})

	if opts.reveal_on_cursor then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = M.augroup,
			pattern = "*.go",
			callback = function(args)
				if not buffer_is_active(args.buf) then
					return
				end
				-- cursor moves are high-frequency; debounce more aggressively
				schedule_refresh(args.buf, opts, opts.debounce_ms or 60)
			end,
		})
	end

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
		group = M.augroup,
		pattern = "*.go",
		callback = function(args)
			on_buf_gone(args.buf)
		end,
	})

	if M.is_globally_enabled then
		local current_buf = vim.api.nvim_get_current_buf()
		if vim.api.nvim_get_option_value("filetype", { buf = current_buf }) == "go" then
			setup_keymaps(current_buf, opts)
			fold.process_buffer(current_buf, opts, M.revealed_blocks[current_buf])
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
	fold.process_buffer(bufnr, config.options, M.revealed_blocks[bufnr])
end

-- GLOBAL COMMANDS

function M.disable()
	if not M.initialized then
		return
	end
	M.is_globally_enabled = false
	M.enabled_buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(bufnr)
			and vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "go"
		then
			fold.clear_extmarks(bufnr)
		end
	end
end

function M.enable()
	if not M.initialized then
		vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
		return
	end
	M.is_globally_enabled = true
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_valid(bufnr)
			and vim.api.nvim_buf_is_loaded(bufnr)
			and vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "go"
			and not M.disabled_buffers[bufnr]
		then
			fold.process_buffer(bufnr, config.options, M.revealed_blocks[bufnr])
		end
	end
end

function M.toggle()
	if not M.initialized then
		vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
		return
	end
	if M.is_globally_enabled then
		M.disable()
	else
		M.enable()
	end
end

-- BUFFER-SPECIFIC COMMANDS

function M.disable_buffer()
	if not M.initialized then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	M.disabled_buffers[bufnr] = true
	M.enabled_buffers[bufnr] = nil
	fold.clear_extmarks(bufnr)
end

function M.enable_buffer()
	if not M.initialized then
		vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	M.disabled_buffers[bufnr] = nil
	if not M.is_globally_enabled then
		M.enabled_buffers[bufnr] = true
	end
	fold.process_buffer(bufnr, config.options, M.revealed_blocks[bufnr])
end

function M.toggle_buffer()
	if not M.initialized then
		vim.notify("no-go.nvim: Plugin not initialized. Call setup() first.", vim.log.levels.WARN)
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	if M.disabled_buffers[bufnr] then
		M.enable_buffer()
	else
		M.disable_buffer()
	end
end

return M

local M = {}

-- ============================================================================
-- 1. STATE & CONSTANTS
-- ============================================================================
M.initialized = false
M.namespace = vim.api.nvim_create_namespace("no-go")
M.is_globally_enabled = true
M.disabled_buffers = {}
M.enabled_buffers = {}
M.keymap_buffers = {}
M.revealed_blocks = {}

local _timers = {}
local _busy = {}
local _error_query = nil
local _import_query = nil

-- ============================================================================
-- 2. DEFAULTS & CONFIG
-- ============================================================================
M.defaults = {
	enabled = true,
	identifiers = { "err" },
	virtual_text = { prefix = "󱞿  ", suffix = "", empty_text = "return" },
	import_virtual_text = { prefix = "󰏗  ", suffix = " " },
	highlight_group = "NoGoZone",
	highlight = { bg = "#2A2A37" },
	update_events = { "BufEnter", "BufWritePost", "TextChanged", "InsertLeave" },
	debounce_ms = 60,
	reveal_on_cursor = false,
	keys = { down = "j", up = "k", toggle = "<M-o>" },
	collapse_imports = true,
}
M.options = {}
M.identifiers_set = {}

local function setup_highlight()
	if M.options.highlight_group == "NoGoZone" then
		local hl = M.options.highlight
		vim.api.nvim_set_hl(0, "NoGoZone", { bg = hl.bg, fg = hl.fg })
	end
end

-- ============================================================================
-- 3. TREESITTER QUERIES
-- ============================================================================
local error_query_new = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      (statement_list
        [
          (return_statement (expression_list)? @return_expr_list)
          (continue_statement) @continue_stmt
          (break_statement) @break_stmt
        ])) @collapse_block
    !alternative) @if_statement
)
]]

local error_query_old = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      [
        (return_statement (expression_list)? @return_expr_list)
        (continue_statement) @continue_stmt
        (break_statement) @break_stmt
      ]) @collapse_block
    !alternative) @if_statement
)
]]

local import_query_str = [[
(import_declaration
  (import_spec_list
    (import_spec
      path: (interpreted_string_literal
        (interpreted_string_literal_content)))
    (import_spec
      path: (interpreted_string_literal
        (interpreted_string_literal_content)))) @collapse_block) @import_statement
]]

local function parse_queries()
	local ok, q = pcall(vim.treesitter.query.parse, "go", error_query_new)
	_error_query = ok and q or vim.treesitter.query.parse("go", error_query_old)
	_import_query = vim.treesitter.query.parse("go", import_query_str)
end

-- ============================================================================
-- 4. UTILITIES
-- ============================================================================
local function get_concealed_range(bufnr, row)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.namespace, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local start_row = mark[2]
		local details = mark[4]
		if details and details.conceal_lines and details.end_row then
			if row >= start_row and row <= details.end_row then
				return { start_row = start_row, end_row = details.end_row }
			end
		end
	end
	return nil
end

local function smart_down_lines(count)
	local bufnr = vim.api.nvim_get_current_buf()
	local current_line = vim.fn.line(".")
	local max_line = vim.fn.line("$")
	local target_line = math.min(current_line + count, max_line)
	local range = get_concealed_range(bufnr, target_line - 1)
	if range then
		target_line = math.min(range.end_row + 2, max_line)
	end
	return target_line - current_line
end

local function smart_up_lines(count)
	local bufnr = vim.api.nvim_get_current_buf()
	local current_line = vim.fn.line(".")
	local target_line = math.max(current_line - count, 1)
	local range = get_concealed_range(bufnr, target_line - 1)
	if range then
		target_line = math.max(range.start_row, 1)
	end
	return current_line - target_line
end

local function is_on_fold_header(bufnr, row)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.namespace, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local start_row = mark[2]
		local details = mark[4]
		if details and details.conceal_lines and start_row == row + 1 then
			return true
		end
	end
	return false
end

local function cursor_in_range(bufnr, start_row, end_row)
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
		if cursor_row >= start_row and cursor_row <= end_row then
			return true
		end
	end
	return false
end

local function find_opening_pair(bufnr, start_row, char)
	local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
	if not line then return nil end
	local brace_col = line:find(char, 1, true)
	return brace_col and (brace_col - 1) or nil
end

local function normalize_return_text(text)
	if not text then return "" end
	local out = text:gsub("[\n\r\t]+", " "):gsub("  +", " ")
	return out:gsub("^%s+", ""):gsub("%s+$", "")
end

-- ============================================================================
-- 5. STATEMENT ANALYZER (SMART SUMMARY)
-- ============================================================================
local function analyze_prior_statements(block_node, bufnr)
	local badges = {}
	local seen = {}

	local function add_badge(name)
		if not seen[name] then
			seen[name] = true
			table.insert(badges, name)
		end
	end

	-- Extract the list of statements, handling both new (nested in statement_list)
	-- and old (direct statement children) tree-sitter-go AST structures.
	local statements = {}
	for child in block_node:iter_children() do
		if child:type() == "statement_list" then
			for stmt in child:iter_children() do
				table.insert(statements, stmt)
			end
		elseif child:type() ~= "{" and child:type() ~= "}" and child:type() ~= ";" then
			table.insert(statements, child)
		end
	end

	for i = 1, #statements - 1 do
		local stmt = statements[i]
		local is_defer = stmt:type() == "defer_statement"
		local call_stmt = stmt
		if is_defer then
			-- In Go treesitter: (defer_statement (call_expression ...))
			call_stmt = stmt:child(0)
		end

		if call_stmt and call_stmt:type() == "expression_statement" then
			call_stmt = call_stmt:child(0)
		end

		if call_stmt and call_stmt:type() == "call_expression" then
			local func_node = call_stmt:field("function")[1]
			if func_node then
				local func_text = vim.treesitter.get_node_text(func_node, bufnr)
				local func_lower = func_text:lower()
				local prefix = is_defer and "defer " or ""
				
				if func_lower:find("log") or func_lower:find("fmt.error") or func_lower:find("slog") or func_lower:find("zap") then
					add_badge(prefix .. "log")
				elseif func_lower:find("inc") or func_lower:find("metric") or func_lower:find("record") then
					add_badge(prefix .. "stats")
				else
					-- Show actual function base name (e.g. Close(), Rollback(), cancel())
					local base_name = func_text:match("([^.]+)$") or func_text
					add_badge(prefix .. base_name .. "()")
				end
			end
		elseif stmt:type() == "assignment_statement" or stmt:type() == "short_var_declaration" then
			add_badge("assign")
		else
			local type_label = is_defer and "defer stmt" or "stmt"
			add_badge(type_label)
		end
	end

	if #badges == 0 then return "" end
	return "[" .. table.concat(badges, ", ") .. "] "
end

-- ============================================================================
-- 6. CONCEAL & FOLDING ENGINES
-- ============================================================================
local function apply_collapse(bufnr, if_node, display_text, block_node, revealed_blocks)
	local if_start_row, _, if_end_row, _ = if_node:range()
	if revealed_blocks and revealed_blocks[if_start_row] then return end
	if M.options.reveal_on_cursor and cursor_in_range(bufnr, if_start_row, if_end_row) then return end

	local brace_start_col = find_opening_pair(bufnr, if_start_row, "{")
	if not brace_start_col then return end

	local if_line = vim.api.nvim_buf_get_lines(bufnr, if_start_row, if_start_row + 1, false)[1]
	if not if_line then return end

	-- Conceal original opening line brace end
	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row, brace_start_col, {
		end_row = if_start_row,
		end_col = #if_line,
		conceal = "",
	})

	-- Hide consequence body lines
	if if_end_row > if_start_row then
		vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row + 1, 0, {
			end_row = if_end_row,
			end_col = 0,
			conceal_lines = "",
		})
	end

	-- Inline display of summary + display_text
	local prefix = M.options.virtual_text.prefix or "󱞿  "
	local suffix = M.options.virtual_text.suffix or ""

	local summary = analyze_prior_statements(block_node, bufnr)
	local virtual_text_string
	if summary ~= "" then
		virtual_text_string = summary .. prefix .. display_text .. suffix
	else
		virtual_text_string = prefix .. display_text .. suffix
	end

	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row, brace_start_col, {
		virt_text = { { virtual_text_string, M.options.highlight_group } },
		virt_text_pos = "inline",
	})
end

local function apply_import_collapse(bufnr, import_node)
	local import_start_row, _, import_end_row, _ = import_node:range()
	if M.options.reveal_on_cursor and cursor_in_range(bufnr, import_start_row, import_end_row) then return end

	local paren_start_col = find_opening_pair(bufnr, import_start_row, "(")
	if not paren_start_col then return end

	local import_line = vim.api.nvim_buf_get_lines(bufnr, import_start_row, import_start_row + 1, false)[1]
	if not import_line then return end

	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, import_start_row, paren_start_col, {
		end_row = import_start_row,
		end_col = #import_line,
		conceal = "",
	})

	if import_end_row > import_start_row then
		vim.api.nvim_buf_set_extmark(bufnr, M.namespace, import_start_row + 1, 0, {
			end_row = import_end_row,
			end_col = 0,
			conceal_lines = "",
		})
	end

	local import_count = 0
	for child in import_node:iter_children() do
		if child:type() == "import_spec_list" then
			for spec_child in child:iter_children() do
				if spec_child:type() == "import_spec" then
					import_count = import_count + 1
				end
			end
			break
		end
	end

	local virtual_text_string = M.options.import_virtual_text.prefix .. import_count .. M.options.import_virtual_text.suffix
	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, import_start_row, paren_start_col, {
		virt_text = { { virtual_text_string, M.options.highlight_group } },
		virt_text_pos = "inline",
	})
end

local function process_error_matches(bufnr, root, revealed_blocks)
	if not _error_query then return end
	local seen = {}
	for _, match, _ in _error_query:iter_matches(root, bufnr, 0, -1, { all = true }) do
		local if_nodes, err_nodes, ret_nodes, collapse_nodes, continue_nodes, break_nodes
		for cap_id, nodes in pairs(match) do
			local name = _error_query.captures[cap_id]
			if name == "if_statement" then if_nodes = nodes
			elseif name == "err_identifier" then err_nodes = nodes
			elseif name == "return_expr_list" then ret_nodes = nodes
			elseif name == "collapse_block" then collapse_nodes = nodes
			elseif name == "continue_stmt" then continue_nodes = nodes
			elseif name == "break_stmt" then break_nodes = nodes
			end
		end

		local if_node = if_nodes and if_nodes[1]
		local err_node = err_nodes and err_nodes[1]
		local collapse_node = collapse_nodes and collapse_nodes[1]
		if if_node and err_node and collapse_node then
			local start_row = select(1, if_node:range())
			if not seen[start_row] then
				local err_text = vim.treesitter.get_node_text(err_node, bufnr)
				if M.identifiers_set[err_text] then
					seen[start_row] = true
					
					local display_text
					if ret_nodes and ret_nodes[1] then
						display_text = normalize_return_text(vim.treesitter.get_node_text(ret_nodes[1], bufnr))
						if display_text == "" then
							display_text = M.options.virtual_text.empty_text or "return"
						end
					elseif continue_nodes and continue_nodes[1] then
						display_text = "continue"
					elseif break_nodes and break_nodes[1] then
						display_text = "break"
					else
						display_text = M.options.virtual_text.empty_text or "return"
					end
					
					apply_collapse(bufnr, if_node, display_text, collapse_node, revealed_blocks)
				end
			end
		end
	end
end

local function process_import_matches(bufnr, root)
	if not _import_query then return end
	local seen = {}
	for _, match, _ in _import_query:iter_matches(root, bufnr, 0, -1, { all = true }) do
		local import_nodes
		for cap_id, nodes in pairs(match) do
			if _import_query.captures[cap_id] == "import_statement" then
				import_nodes = nodes
			end
		end
		local import_node = import_nodes and import_nodes[1]
		if import_node then
			local start_row = select(1, import_node:range())
			if not seen[start_row] then
				seen[start_row] = true
				apply_import_collapse(bufnr, import_node)
			end
		end
	end
end

local function buffer_is_active(bufnr)
	if M.disabled_buffers[bufnr] then return false end
	if not M.is_globally_enabled and not M.enabled_buffers[bufnr] then return false end
	return true
end

function M.process_buffer(bufnr, revealed_blocks)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if vim.api.nvim_get_option_value("filetype", { buf = bufnr }) ~= "go" then return end
	if _busy[bufnr] then return end
	_busy[bufnr] = true

	pcall(function()
		vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
		vim.api.nvim_buf_call(bufnr, function()
			vim.wo.conceallevel = 2
			vim.wo.concealcursor = "nvic"
		end)

		local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "go")
		if not parser_ok or not parser then return end

		local tree = parser:parse()[1]
		if not tree then return end

		local root = tree:root()
		process_error_matches(bufnr, root, revealed_blocks)
		if M.options.collapse_imports then
			process_import_matches(bufnr, root)
		end
	end)
	_busy[bufnr] = nil
end

-- ============================================================================
-- 7. TIMERS & REFRESHES
-- ============================================================================
local function schedule_refresh(bufnr, delay_ms)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then return end

	local existing = _timers[bufnr]
	if existing then
		existing:stop()
		existing:close()
		_timers[bufnr] = nil
	end

	local timer = vim.uv.new_timer()
	if not timer then
		M.process_buffer(bufnr, M.revealed_blocks[bufnr])
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
				M.process_buffer(bufnr, M.revealed_blocks[bufnr])
			end
		end)
	)
end

-- ============================================================================
-- 8. KEYMAPS & AUTOCOMMANDS
-- ============================================================================
local function setup_keymaps(bufnr)
	if M.keymap_buffers[bufnr] or not M.options.keys then return end

	local keys = M.options.keys
	if keys.down then
		vim.keymap.set({ "n", "x", "o" }, keys.down, function()
			if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then return "j" end
			local lines = smart_down_lines(vim.v.count1)
			return lines > 0 and (lines .. "j") or ""
		end, { buffer = bufnr, desc = "Smart down", expr = true })
	end

	if keys.up then
		vim.keymap.set({ "n", "x", "o" }, keys.up, function()
			if vim.fn.reg_recording() ~= "" or vim.fn.reg_executing() ~= "" then return "k" end
			local lines = smart_up_lines(vim.v.count1)
			return lines > 0 and (lines .. "k") or ""
		end, { buffer = bufnr, desc = "Smart up", expr = true })
	end

	if keys.toggle then
		vim.keymap.set({ "n", "x", "o" }, keys.toggle, function()
			local current_buf = vim.api.nvim_get_current_buf()
			local row = vim.fn.line(".") - 1
			if not M.revealed_blocks[current_buf] then M.revealed_blocks[current_buf] = {} end

			local view = vim.fn.winsaveview()
			if M.revealed_blocks[current_buf][row] then
				M.revealed_blocks[current_buf][row] = nil
				M.process_buffer(current_buf, M.revealed_blocks[current_buf])
				vim.fn.winrestview(view)
				return
			end

			if is_on_fold_header(current_buf, row) then
				M.revealed_blocks[current_buf][row] = true
				-- Temporarily override reveal_on_cursor to unfold this block
				local prev_reveal = M.options.reveal_on_cursor
				M.options.reveal_on_cursor = true
				M.process_buffer(current_buf, M.revealed_blocks[current_buf])
				M.options.reveal_on_cursor = prev_reveal
				vim.fn.winrestview(view)
				return
			end
			vim.notify("no-go: not on a concealed block", vim.log.levels.INFO)
		end, { buffer = bufnr, desc = "Toggle fold under cursor" })
	end

	M.keymap_buffers[bufnr] = true
end

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
	M.revealed_blocks[bufnr] = nil
end

-- ============================================================================
-- 9. PUBLIC API & COMMANDS
-- ============================================================================
function M.setup(user_config)
	M.options = vim.tbl_deep_extend("force", M.defaults, user_config or {})
	M.identifiers_set = {}
	for _, id in ipairs(M.options.identifiers) do
		M.identifiers_set[id] = true
	end

	setup_highlight()
	parse_queries()

	local augroup = vim.api.nvim_create_augroup("NoGo", { clear = true })

	vim.api.nvim_create_autocmd(M.options.update_events, {
		group = augroup,
		pattern = "*.go",
		callback = function(args)
			setup_keymaps(args.buf)
			if not buffer_is_active(args.buf) then return end
			schedule_refresh(args.buf, M.options.debounce_ms or 60)
		end,
	})

	if M.options.reveal_on_cursor then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = augroup,
			pattern = "*.go",
			callback = function(args)
				if not buffer_is_active(args.buf) then return end
				schedule_refresh(args.buf, M.options.debounce_ms or 60)
			end,
		})
	end

	vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
		group = augroup,
		pattern = "*.go",
		callback = function(args)
			on_buf_gone(args.buf)
		end,
	})

	-- Apply initial folding on load if already in a Go buffer
	if M.options.enabled then
		local current_buf = vim.api.nvim_get_current_buf()
		if vim.api.nvim_get_option_value("filetype", { buf = current_buf }) == "go" then
			setup_keymaps(current_buf)
			M.process_buffer(current_buf, M.revealed_blocks[current_buf])
		end
	end

	M.initialized = true
end

function M.disable()
	if not M.initialized then return end
	M.is_globally_enabled = false
	M.enabled_buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "go" then
			vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
		end
	end
end

function M.enable()
	if not M.initialized then return end
	M.is_globally_enabled = true
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "go" and not M.disabled_buffers[bufnr] then
			M.process_buffer(bufnr, M.revealed_blocks[bufnr])
		end
	end
end

function M.toggle()
	if M.is_globally_enabled then M.disable() else M.enable() end
end

function M.disable_buffer()
	if not M.initialized then return end
	local bufnr = vim.api.nvim_get_current_buf()
	M.disabled_buffers[bufnr] = true
	M.enabled_buffers[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
end

function M.enable_buffer()
	if not M.initialized then return end
	local bufnr = vim.api.nvim_get_current_buf()
	M.disabled_buffers[bufnr] = nil
	if not M.is_globally_enabled then M.enabled_buffers[bufnr] = true end
	M.process_buffer(bufnr, M.revealed_blocks[bufnr])
end

function M.toggle_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	if M.disabled_buffers[bufnr] then M.enable_buffer() else M.disable_buffer() end
end

return M

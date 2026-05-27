local M = {}
local utils = require("no-go.utils")
local queries = require("no-go.queries")

M.namespace = vim.api.nvim_create_namespace("no-go")

-- Cached parsed queries (parse once, reuse)
local _error_query
local _import_query

-- Per-buffer reentrancy guard: prevents process_buffer from re-entering itself
-- when extmark operations or window calls trigger autocmds.
local _busy = {}

--- Parse and return the Treesitter query for Go error handling patterns
--- @return vim.treesitter.Query|nil query The parsed query or nil if parsing fails
function M.get_error_query()
	if _error_query then
		return _error_query
	end
	local ok, query = pcall(vim.treesitter.query.parse, "go", queries.error_query)
	if not ok then
		local has_parser = pcall(vim.treesitter.language.inspect, "go")
		if not has_parser then
			vim.notify("no-go.nvim: Go parser not found. Install it with :TSInstall go", vim.log.levels.ERROR)
		else
			vim.notify(
				"no-go.nvim: Failed to parse error query. Try updating the parser with :TSUpdate go",
				vim.log.levels.ERROR
			)
		end
		return nil
	end
	_error_query = query
	return _error_query
end

--- Parse and return the Treesitter query for Go import blocks
--- @return vim.treesitter.Query|nil query The parsed query or nil if parsing fails
function M.get_import_query()
	if _import_query then
		return _import_query
	end
	local ok, query = pcall(vim.treesitter.query.parse, "go", queries.import_query)
	if not ok then
		local has_parser = pcall(vim.treesitter.language.inspect, "go")
		if not has_parser then
			vim.notify("no-go.nvim: Go parser not found. Install it with :TSInstall go", vim.log.levels.ERROR)
		else
			vim.notify(
				"no-go.nvim: Failed to parse import query. Try updating the parser with :TSUpdate go",
				vim.log.levels.ERROR
			)
		end
		return nil
	end
	_import_query = query
	return _import_query
end

--- Clear all extmarks in the specified buffer
--- @param bufnr number The buffer number
function M.clear_extmarks(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
end

--- True if cursor in any window showing `bufnr` sits between start_row..end_row (inclusive, 0-indexed).
local function cursor_in_range(bufnr, start_row, end_row)
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
		if cursor_row >= start_row and cursor_row <= end_row then
			return true
		end
	end
	return false
end

--- Apply virtual text and concealment to collapse an error handling block
--- @param bufnr number The buffer number
--- @param if_node TSNode The if statement node
--- @param return_text string|nil The literal text of the return expression list, or nil
--- @param config table The plugin configuration
--- @param revealed_blocks table|nil Table of manually revealed block rows
function M.apply_collapse(bufnr, if_node, return_text, config, revealed_blocks)
	local if_start_row, _, if_end_row, _ = if_node:range()

	-- check if this block is manually revealed (toggled open)
	if revealed_blocks and revealed_blocks[if_start_row] then
		return
	end

	-- check if cursor is inside this block to avoid folding code the user is editing
	if config.reveal_on_cursor and cursor_in_range(bufnr, if_start_row, if_end_row) then
		return
	end

	local brace_start_col = utils.find_opening_pair(bufnr, if_start_row, "{")
	if not brace_start_col then
		return
	end

	-- Conceal from { to end of the if line
	local if_line = vim.api.nvim_buf_get_lines(bufnr, if_start_row, if_start_row + 1, false)[1]
	if not if_line then
		return
	end

	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row, brace_start_col, {
		end_row = if_start_row,
		end_col = #if_line,
		conceal = "",
	})

	-- Hide intermediate lines + closing brace (end_row inclusive)
	if if_end_row > if_start_row then
		vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row + 1, 0, {
			end_row = if_end_row,
			end_col = 0,
			conceal_lines = "",
		})
	end

	local virtual_text_string = utils.build_virtual_text(return_text, config)
	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, if_start_row, brace_start_col, {
		virt_text = { { virtual_text_string, config.highlight_group } },
		virt_text_pos = "inline",
	})
end

--- Apply virtual text and concealment to collapse an import block
--- @param bufnr number The buffer number
--- @param import_node TSNode The import statement node
--- @param config table The plugin configuration
function M.apply_import_collapse(bufnr, import_node, config)
	local import_start_row, _, import_end_row, _ = import_node:range()

	if config.reveal_on_cursor and cursor_in_range(bufnr, import_start_row, import_end_row) then
		return
	end

	local paren_start_col = utils.find_opening_pair(bufnr, import_start_row, "(")
	if not paren_start_col then
		return
	end

	local import_line = vim.api.nvim_buf_get_lines(bufnr, import_start_row, import_start_row + 1, false)[1]
	if not import_line then
		return
	end

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

	local virtual_text_string = config.import_virtual_text.prefix .. import_count .. config.import_virtual_text.suffix
	vim.api.nvim_buf_set_extmark(bufnr, M.namespace, import_start_row, paren_start_col, {
		virt_text = { { virtual_text_string, config.highlight_group } },
		virt_text_pos = "inline",
	})
end

--- Walk error_query matches, applying collapse to each matched if_statement.
--- Dedupes by if_node start row so the same if can't be collapsed twice in one pass.
local function process_error_matches(bufnr, root, config, revealed_blocks)
	local error_query = M.get_error_query()
	if not error_query then
		return
	end

	local seen = {}
	for _, match, _ in error_query:iter_matches(root, bufnr, 0, -1, { all = true }) do
		local if_nodes = nil
		local err_nodes = nil
		local ret_nodes = nil
		local collapse_nodes = nil

		for cap_id, nodes in pairs(match) do
			local name = error_query.captures[cap_id]
			if name == "if_statement" then
				if_nodes = nodes
			elseif name == "err_identifier" then
				err_nodes = nodes
			elseif name == "return_expr_list" then
				ret_nodes = nodes
			elseif name == "collapse_block" then
				collapse_nodes = nodes
			end
		end

		local if_node = if_nodes and if_nodes[1]
		local err_node = err_nodes and err_nodes[1]
		local collapse_node = collapse_nodes and collapse_nodes[1]
		if if_node and err_node and collapse_node then
			local start_row = select(1, if_node:range())
			if not seen[start_row] and utils.is_configured_identifier(err_node, bufnr, config) then
				seen[start_row] = true
				local return_text
				if ret_nodes and ret_nodes[1] then
					return_text = vim.treesitter.get_node_text(ret_nodes[1], bufnr)
				end
				M.apply_collapse(bufnr, if_node, return_text, config, revealed_blocks)
			end
		end
	end
end

--- Walk import_query matches.
local function process_import_matches(bufnr, root, config)
	local import_query = M.get_import_query()
	if not import_query then
		return
	end

	local seen = {}
	for _, match, _ in import_query:iter_matches(root, bufnr, 0, -1, { all = true }) do
		local import_nodes = nil
		for cap_id, nodes in pairs(match) do
			local name = import_query.captures[cap_id]
			if name == "import_statement" then
				import_nodes = nodes
			end
		end

		local import_node = import_nodes and import_nodes[1]
		if import_node then
			local start_row = select(1, import_node:range())
			if not seen[start_row] then
				seen[start_row] = true
				M.apply_import_collapse(bufnr, import_node, config)
			end
		end
	end
end

--- Process buffer and apply collapses to error handling blocks
--- @param bufnr number|nil The buffer number (defaults to current buffer)
--- @param config table The plugin configuration
--- @param revealed_blocks table|nil Table of manually revealed block rows
function M.process_buffer(bufnr, config, revealed_blocks)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- check if buffer is a go file early
	if vim.api.nvim_get_option_value("filetype", { buf = bufnr }) ~= "go" then
		return
	end

	-- reentrancy guard: skip if another process_buffer is mid-flight for this buffer
	if _busy[bufnr] then
		return
	end
	_busy[bufnr] = true

	local ok, err = pcall(function()
		M.clear_extmarks(bufnr)

		-- set conceallevel at the window level so concealing works
		vim.api.nvim_buf_call(bufnr, function()
			vim.wo.conceallevel = 2
			vim.wo.concealcursor = "nvic" -- conceal in all modes
		end)

		local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "go")
		if not parser_ok or not parser then
			return
		end

		local tree = parser:parse()[1]
		if not tree then
			return
		end

		local root = tree:root()
		process_error_matches(bufnr, root, config, revealed_blocks)
		if config.collapse_imports then
			process_import_matches(bufnr, root, config)
		end
	end)

	_busy[bufnr] = nil
	if not ok then
		vim.notify("no-go.nvim: process_buffer error: " .. tostring(err), vim.log.levels.ERROR)
	end
end

return M

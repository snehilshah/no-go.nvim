local M = {}

-- Query for newer tree-sitter-go (main branch) where block contains statement_list
local error_query_with_statement_list = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      (statement_list
        (return_statement
          (expression_list
            (identifier) @return_identifier)?))) @collapse_block
    !alternative) @if_statement
)
]]

-- Query for older tree-sitter-go where block directly contains statements
local error_query_without_statement_list = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      (return_statement
        (expression_list
          (identifier) @return_identifier)?)) @collapse_block
    !alternative) @if_statement
)
]]

-- Detect which query works with the current tree-sitter-go grammar
local function get_error_query()
  -- Try the newer query first (with statement_list)
  local ok = pcall(vim.treesitter.query.parse, "go", error_query_with_statement_list)
  if ok then
    return error_query_with_statement_list
  end
  -- Fall back to older query (without statement_list)
  return error_query_without_statement_list
end

-- Cache the detected query
M.error_query = get_error_query()

M.import_query = [[
(import_declaration
  (import_spec_list) @import_list) @import_block
]]

return M

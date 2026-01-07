-- Test query compatibility
local error_query = [[
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

local ok, err = pcall(vim.treesitter.query.parse, "go", error_query)
if ok then
  print("Query parsed successfully!")
else
  print("Query failed: " .. tostring(err))
  
  -- Try without !alternative
  local simpler = [[
(
  (if_statement
    condition: (binary_expression
      left: (identifier) @err_identifier)
    consequence: (block
      (statement_list
        (return_statement
          (expression_list
            (identifier) @return_identifier)?))) @collapse_block) @if_statement
)
]]
  local ok2, err2 = pcall(vim.treesitter.query.parse, "go", simpler)
  print("Without !alternative: " .. (ok2 and "OK" or tostring(err2)))
end

local M = {}

-- Only match if statements WITHOUT an else/else-if clause
-- The !alternative ensures we don't match if statements that have else clauses
-- Note: As of tree-sitter-go main branch, block contains statement_list again
M.error_query = [[
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

M.import_query = [[
(import_declaration
  (import_spec_list) @import_list) @import_block
]]

return M
